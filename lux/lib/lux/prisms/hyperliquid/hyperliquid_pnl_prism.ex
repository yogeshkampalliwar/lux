defmodule Lux.Prisms.Hyperliquid.HyperliquidPnlPrism do
  @moduledoc """
  A prism that fetches PnL and trade history from Hyperliquid.

  ## Example

      iex> Lux.Prisms.Hyperliquid.HyperliquidPnlPrism.run(%{
      ...>   address: "0x0403369c02199a0cb827f4d6492927e9fa5668d5"
      ...> })
      {:ok, %{status: "success", pnl_data: %{}}}
  """

  use Lux.Prism,
    name: "Hyperliquid PnL Tracker",
    description: "Fetches PnL and trade history from Hyperliquid",
    input_schema: %{
      type: :object,
      properties: %{
        address: %{
          type: :string,
          description: "Ethereum address to fetch PnL for",
          pattern: "^0x[a-fA-F0-9]{40}$"
        }
      },
      required: ["address"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        pnl_data: %{
          type: :object,
          properties: %{
            total_realized_pnl: %{type: :string},
            total_unrealized_pnl: %{type: :string},
            positions: %{type: :array}
          }
        }
      },
      required: ["status", "pnl_data"]
    }

  import Lux.Python
  alias Lux.Config
  require Lux.Python

  def handler(%{address: address}, _ctx) do
    with {:ok, private_key} <- get_private_key(),
         {:ok, api_url} <- {:ok, Config.hyperliquid_api_url()},
         {:ok, %{"success" => true}} <- Lux.Python.import_package("hyperliquid.info"),
         {:ok, %{"success" => true}} <- Lux.Python.import_package("hyperliquid_utils.setup"),
         {:ok, result} <- fetch_pnl(private_key, address, api_url) do
      {:ok, %{status: "success", pnl_data: result}}
    else
      {:error, :missing_private_key} -> {:error, "Hyperliquid account private key is not configured"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_private_key do
    {:ok, Config.hyperliquid_account_key()}
  rescue
    RuntimeError -> {:error, :missing_private_key}
  end

  defp fetch_pnl(private_key, address, api_url) do
    python_result =
      python variables: %{private_key: private_key, address: address, api_url: api_url} do
        ~PY"""
        from hyperliquid.info import Info
        from hyperliquid_utils.setup import setup

        _, info, _ = setup(private_key, address, api_url, skip_ws=True)
        user_state = info.user_state(address)

        total_unrealized = 0.0
        positions = []

        for pos in user_state.get("assetPositions", []):
          p = pos["position"]
          unrealized = float(p.get("unrealizedPnl", 0))
          total_unrealized += unrealized
          positions.append({
            "coin": p["coin"],
            "size": p.get("szi", "0"),
            "entry_price": p.get("entryPx", "0"),
            "unrealized_pnl": str(unrealized),
            "return_on_equity": p.get("returnOnEquity", "0"),
            "liquidation_price": p.get("liquidationPx"),
            "leverage_type": p.get("leverage", {}).get("type", "cross"),
            "leverage_value": str(p.get("leverage", {}).get("value", 1)),
            "margin_used": p.get("marginUsed", "0"),
            "position_value": p.get("positionValue", "0")
          })

        {
          "total_unrealized_pnl": str(total_unrealized),
          "total_realized_pnl": "0",
          "positions": positions
        }
        """
      end

    case python_result do
      %{"error" => error} -> {:error, error}
      result when is_map(result) -> {:ok, result}
    end
  end
end
