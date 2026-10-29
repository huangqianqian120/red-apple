// Command hongguo-sidecar 把 openhongguo SDK 包成一条 JSON 管道，
// 供 Swift 写的桌面 App 调用。
//
// 为什么不用 gomobile：`gomobile bind -target macos` 强制要求完整 Xcode，
// 而 `go build` 用纯 Go 就能产出原生 arm64 二进制。协议只有一行一请求、
// 一行一响应，跨语言边界就一个 JSON 契约（见 README「sidecar 协议」）。
//
// 用法：
//
//	hongguo-sidecar -profile /path/anonymous.json
//
// stdin 每行一个请求：{"id":1,"method":"search","args":["末世"]}
// stdout 每行一个响应：{"id":1,"result":{...}} 或 {"id":1,"error":{...}}
// 诊断信息只写 stderr，不会污染协议流。
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime/debug"
	"sync"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
)

type request struct {
	ID     int               `json:"id"`
	Method string            `json:"method"`
	Args   []json.RawMessage `json:"args"`
}

type response struct {
	ID     int         `json:"id"`
	Result any         `json:"result,omitempty"`
	Error  *wireError  `json:"error,omitempty"`
}

type wireError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
	RetryMs   int64  `json:"retryAfterMs,omitempty"`
}

// 下面是跨语言契约里的输出类型。刻意不复用 sdk 的结构体：
// 这样上游改字段不会悄悄改变 App 的解析结果。

type summary struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	CoverURL     string `json:"coverUrl,omitempty"`
	EpisodeCount int    `json:"episodeCount,omitempty"`
	Author       string `json:"author,omitempty"`
	Category     string `json:"category,omitempty"`
	Summary      string `json:"summary,omitempty"`
}

type page struct {
	Items   []summary `json:"items"`
	Cursor  string    `json:"cursor,omitempty"`
	HasMore bool      `json:"hasMore"`
}

type series struct {
	ID           string   `json:"id"`
	Title        string   `json:"title"`
	CoverURL     string   `json:"coverUrl,omitempty"`
	EpisodeCount int      `json:"episodeCount,omitempty"`
	Summary      string   `json:"summary,omitempty"`
	Author       string   `json:"author,omitempty"`
	Tags         []string `json:"tags,omitempty"`
	Heat         int64    `json:"heat,omitempty"`
}

type episode struct {
	ID       string `json:"id"`
	SeriesID string `json:"seriesId"`
	Number   int    `json:"number"`
	Title    string `json:"title,omitempty"`
	Playable bool   `json:"playable"`
	Vertical bool   `json:"vertical"`
}

type episodePage struct {
	Items   []episode `json:"items"`
	Cursor  string    `json:"cursor,omitempty"`
	HasMore bool      `json:"hasMore"`
}

type stream struct {
	Definition string `json:"definition,omitempty"`
	Codec      string `json:"codec,omitempty"`
	Width      int    `json:"width,omitempty"`
	Height     int    `json:"height,omitempty"`
	Bitrate    int64  `json:"bitrate,omitempty"`
	URL        string `json:"url"`
	BackupURL  string `json:"backupUrl,omitempty"`
	HLS        bool   `json:"hls,omitempty"`
	Dash       bool   `json:"dash,omitempty"`
	Protected  bool   `json:"protected"`
	Encryption string `json:"encryption,omitempty"`
}

type playback struct {
	EpisodeID       string   `json:"episodeId"`
	DurationSeconds int      `json:"durationSeconds,omitempty"`
	Protected       bool     `json:"protected"`
	AudioURL        string   `json:"audioUrl,omitempty"`
	Key             string   `json:"key,omitempty"`
	KeyVersion      string   `json:"keyVersion,omitempty"`
	Streams         []stream `json:"streams"`
}

type rankEntry struct {
	Rank         int    `json:"rank"`
	Position     int    `json:"position,omitempty"`
	SeriesID     string `json:"seriesId,omitempty"`
	Title        string `json:"title,omitempty"`
	Score        string `json:"score,omitempty"`
	Actor        string `json:"actor,omitempty"`
	CoverURL     string `json:"coverUrl,omitempty"`
	EpisodeCount int    `json:"episodeCount,omitempty"`
	Promoted     bool   `json:"promoted,omitempty"`
}

func main() {
	profile := flag.String("profile", "", "匿名设备档案路径（空则用 SDK 默认位置）")
	retries := flag.Int("retries", 3, "可重试失败的最多尝试次数")
	flag.Parse()

	client, err := adapters.NewClient(*profile, sdk.Options{RetryAttempts: *retries})
	if err != nil {
		fmt.Fprintf(os.Stderr, "sidecar: 创建客户端失败：%v\n", err)
		os.Exit(1)
	}

	// 每个请求在自己的 goroutine 里跑：浏览页的 discover 有 3 秒，不能让它
	// 把播放请求堵在后面（App 启动时会同时发浏览和播放两类请求）。
	// 响应按 id 匹配，可以乱序回来；写 stdout 要加锁。
	var writeMu sync.Mutex
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			fmt.Fprintf(os.Stderr, "sidecar: 请求不是 JSON：%v\n", err)
			continue
		}
		go func(req request) {
			result, callErr := dispatch(client, req)

			// 匿名设备有额度：撞到 anonymous_limited 时自动换一台再试一次。
			// 只重试一次——连续限流说明这台机器被针对了，继续换也没用。
			if errors.Is(callErr, sdk.ErrAnonymousLimited) {
				fmt.Fprintln(os.Stderr, "sidecar: 匿名设备额度用尽，换一台重试")
				resetCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				resetErr := client.ResetDevice(resetCtx)
				cancel()
				if resetErr != nil {
					fmt.Fprintf(os.Stderr, "sidecar: 换设备失败：%v\n", resetErr)
				} else {
					result, callErr = dispatch(client, req)
				}
			}
			resp := response{ID: req.ID, Result: result}
			if callErr != nil {
				retryAfter := sdk.RetryAfter(callErr, 0)
				resp = response{ID: req.ID, Error: &wireError{
					Code:      errorCode(callErr),
					Message:   callErr.Error(),
					Retryable: sdk.Retryable(callErr),
					RetryMs:   retryAfter.Milliseconds(),
				}}
			}
			writeMu.Lock()
			defer writeMu.Unlock()
			if err := enc.Encode(resp); err != nil {
				fmt.Fprintf(os.Stderr, "sidecar: 写响应失败：%v\n", err)
			}
		}(req)
	}
}

func dispatch(c *sdk.Client, req request) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	switch req.Method {
	case "ping":
		return map[string]any{"ok": true, "version": buildVersion()}, nil

	case "discover":
		// args: [频道?, 游标?]；频道取 SDK 认识的名字（推荐/电影/剧集…）。
		var channel, cursor string
		if len(req.Args) > 0 {
			_ = json.Unmarshal(req.Args[0], &channel)
		}
		if len(req.Args) > 1 {
			_ = json.Unmarshal(req.Args[1], &cursor)
		}
		p, err := c.Discover(ctx, sdk.DiscoverOptions{Channel: channel, Cursor: cursor})
		if err != nil {
			return nil, err
		}
		return toPage(p), nil

	case "channels":
		return map[string]any{"channels": []string{
			"推荐", "电影", "找剧", "经典", "真人剧", "漫剧", "大视听",
		}}, nil

	case "search":
		var query string
		if err := decodeArgs(req.Args, &query); err != nil {
			return nil, err
		}
		p, err := c.Search(ctx, query, sdk.SearchOptions{})
		if err != nil {
			return nil, err
		}
		return toPage(p), nil

	case "series":
		var id string
		if err := decodeArgs(req.Args, &id); err != nil {
			return nil, err
		}
		s, err := c.GetSeries(ctx, id)
		if err != nil {
			return nil, err
		}
		return toSeries(s), nil

	case "episodes":
		var id string
		if err := decodeArgs(req.Args, &id); err != nil {
			return nil, err
		}
		p, err := c.ListEpisodes(ctx, id, sdk.EpisodeOptions{})
		if err != nil {
			return nil, err
		}
		items := make([]episode, 0, len(p.Items))
		for _, e := range p.Items {
			items = append(items, episode{
				ID: e.ID, SeriesID: e.SeriesID, Number: e.Number, Title: e.Title,
				Playable: e.Playable, Vertical: e.Vertical,
			})
		}
		return episodePage{Items: items, Cursor: p.Cursor, HasMore: p.HasMore}, nil

	case "playback":
		var id string
		if err := decodeArgs(req.Args, &id); err != nil {
			return nil, err
		}
		pb, err := c.ResolvePlayback(ctx, id, sdk.PlaybackOptions{})
		if pb == nil {
			return nil, err
		}
		out := toPlayback(pb)
		// 加密分集顺手把内容密钥解出来：App 只关心「能播的地址 + 密钥」。
		if key, keyErr := sdk.ContentKey(pb); keyErr == nil {
			out.Key = key.Hex
			out.KeyVersion = key.Version
		} else if err == nil {
			// ErrDRMProtected 是预期内的，其他错误随响应带回去。
			err = keyErr
		}
		return out, nil

	case "resetDevice":
		// 匿名设备被服务端限流/拒绝时，换一台虚拟手机继续。
		if err := c.ResetDevice(ctx); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil

	case "shortRank":
		r, err := c.ShortRank(ctx, sdk.ShortRankQuery{})
		if err != nil {
			return nil, err
		}
		items := make([]rankEntry, 0, len(r.Items))
		for _, item := range r.Items {
			items = append(items, rankEntry{
				Rank: item.Rank, Position: item.Position, SeriesID: item.SeriesID,
				Title: item.Title, Score: item.Score, Actor: item.Actor,
				CoverURL: item.CoverURL, EpisodeCount: item.EpisodeCount, Promoted: item.Promoted,
			})
		}
		return map[string]any{"items": items, "hasMore": r.HasMore, "cursor": r.Cursor}, nil

	default:
		return nil, fmt.Errorf("未知方法 %q", req.Method)
	}
}

func decodeArgs(args []json.RawMessage, target *string) error {
	if len(args) == 0 {
		return fmt.Errorf("缺少参数")
	}
	return json.Unmarshal(args[0], target)
}

func toPage(p *sdk.Page[model.SeriesSummary]) page {
	items := make([]summary, 0, len(p.Items))
	for _, s := range p.Items {
		items = append(items, summary{
			ID: s.ID, Title: s.Title, CoverURL: s.CoverURL, EpisodeCount: s.EpisodeCount,
			Author: s.Author, Category: s.Category, Summary: s.Description,
		})
	}
	return page{Items: items, Cursor: p.Cursor, HasMore: p.HasMore}
}

func toSeries(s *model.Series) series {
	return series{
		ID: s.ID, Title: s.Title, CoverURL: s.CoverURL, EpisodeCount: s.EpisodeCount,
		Summary: s.Description, Author: s.Author, Tags: s.Subtitles, Heat: s.Heat,
	}
}

func toPlayback(pb *model.Playback) playback {
	streams := make([]stream, 0, len(pb.Streams))
	for _, s := range pb.Streams {
		streams = append(streams, stream{
			Definition: s.Definition, Codec: s.Codec, Width: s.Width, Height: s.Height,
			Bitrate: s.Bitrate, URL: s.URL, BackupURL: s.BackupURL,
			HLS: s.HLS, Dash: s.Dash, Protected: s.Protected, Encryption: s.Encryption,
		})
	}
	return playback{
		EpisodeID: pb.EpisodeID, DurationSeconds: pb.DurationSeconds, Protected: pb.Protected,
		AudioURL: pb.AudioURL, Streams: streams,
	}
}

// buildVersion 是链接进二进制的 SDK 版本，方便 App 显示来源。
func buildVersion() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == "github.com/beilunyang/openhongguo" {
				return dep.Version
			}
		}
	}
	return "devel"
}

// errorCode 给 App 一个稳定的错误分类，而不是让它解析中文错误信息。
func errorCode(err error) string {
	kind := "unknown"
	switch {
	case errors.Is(err, sdk.ErrRateLimited):
		kind = "rate_limited"
	case errors.Is(err, sdk.ErrTransport):
		kind = "transport"
	case errors.Is(err, sdk.ErrContentUnavailable):
		kind = "content_unavailable"
	case errors.Is(err, sdk.ErrAnonymousLimited):
		kind = "anonymous_limited"
	case errors.Is(err, sdk.ErrDRMProtected):
		kind = "drm_protected"
	case errors.Is(err, sdk.ErrNotProtected):
		kind = "not_protected"
	case errors.Is(err, sdk.ErrAuthenticationRequired):
		kind = "authentication_required"
	case errors.Is(err, sdk.ErrChallengeRequired):
		kind = "challenge_required"
	case errors.Is(err, sdk.ErrDeviceRejected):
		kind = "device_rejected"
	case errors.Is(err, sdk.ErrSignatureRejected):
		kind = "signature_rejected"
	case errors.Is(err, sdk.ErrParamInvalid):
		kind = "param_invalid"
	case errors.Is(err, sdk.ErrEndOfList):
		kind = "end_of_list"
	case errors.Is(err, sdk.ErrProfileNotFound):
		kind = "profile_not_found"
	}
	return kind
}

