defmodule Lux.Prisms.YouTube.YouTubeAnalyticsPrism do
  @moduledoc """
  A prism for fetching YouTube channel and video analytics.
  """

  use Lux.Prism,
    name: "YouTube Analytics",
    description: "Fetches YouTube channel and video analytics via YouTube Analytics API",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string, enum: ["channel_stats", "video_stats", "top_videos"]},
        video_id: %{type: :string},
        start_date: %{type: :string, description: "YYYY-MM-DD"},
        end_date: %{type: :string, description: "YYYY-MM-DD"},
        max_results: %{type: :integer, default: 10}
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        stats: %{type: :object},
        videos: %{type: :array}
      },
      required: ["status"]
    }

  require Logger

  @api "https://www.googleapis.com/youtube/v3"

  def handler(input, _ctx) do
    with {:ok, api_key} <- get_api_key() do
      case input.action do
        "channel_stats" -> get_channel_stats(api_key)
        "video_stats"   -> get_video_stats(api_key, input.video_id)
        "top_videos"    -> get_top_videos(api_key, input)
        _               -> {:error, "Unknown action: #{input.action}"}
      end
    end
  end

  defp get_api_key do
    key = Lux.Config.get(:youtube_api_key) || System.get_env("YOUTUBE_API_KEY")
    if key, do: {:ok, key}, else: {:error, "YouTube API key not configured"}
  rescue
    _ -> {:error, "YouTube API key not configured"}
  end

  defp get_channel_stats(api_key) do
    case Req.get("#{@api}/channels",
      params: %{part: "snippet,statistics,contentDetails", mine: true, key: api_key}
    ) do
      {:ok, %{status: 200, body: %{"items" => [channel | _]}}} ->
        stats = channel["statistics"] || %{}
        {:ok, %{
          status: "success",
          stats: %{
            channel_id: channel["id"],
            title: get_in(channel, ["snippet", "title"]),
            subscribers: stats["subscriberCount"],
            total_views: stats["viewCount"],
            video_count: stats["videoCount"],
            description: get_in(channel, ["snippet", "description"])
          }
        }}
      {:ok, %{status: s, body: b}} -> {:error, "Error #{s}: #{inspect(b)}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  defp get_video_stats(api_key, video_id) do
    case Req.get("#{@api}/videos",
      params: %{part: "snippet,statistics,status", id: video_id, key: api_key}
    ) do
      {:ok, %{status: 200, body: %{"items" => [video | _]}}} ->
        stats = video["statistics"] || %{}
        {:ok, %{
          status: "success",
          stats: %{
            video_id: video["id"],
            title: get_in(video, ["snippet", "title"]),
            views: stats["viewCount"],
            likes: stats["likeCount"],
            comments: stats["commentCount"],
            published_at: get_in(video, ["snippet", "publishedAt"])
          }
        }}
      {:ok, %{status: 200}} -> {:error, "Video not found"}
      {:ok, %{status: s, body: b}} -> {:error, "Error #{s}: #{inspect(b)}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  defp get_top_videos(api_key, input) do
    case Req.get("#{@api}/videos",
      params: %{
        part: "snippet,statistics",
        chart: "mostPopular",
        maxResults: Map.get(input, :max_results, 10),
        key: api_key
      }
    ) do
      {:ok, %{status: 200, body: body}} ->
        videos = Enum.map(body["items"] || [], fn v ->
          %{
            id: v["id"],
            title: get_in(v, ["snippet", "title"]),
            views: get_in(v, ["statistics", "viewCount"]),
            likes: get_in(v, ["statistics", "likeCount"])
          }
        end)
        {:ok, %{status: "success", videos: videos}}
      {:ok, %{status: s, body: b}} -> {:error, "Error #{s}: #{inspect(b)}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end
end
