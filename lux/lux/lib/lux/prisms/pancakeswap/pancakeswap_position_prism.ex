defmodule Lux.Prisms.Pancakeswap.PancakeswapPositionPrism do
  @moduledoc """
  A prism for tracking positions and APY on PancakeSwap.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapPositionPrism.handler(%{
      ...>   wallet_address: "0x1234567890abcdef",
      ...>   chain_id: 56
      ...> }, %{})
  """

  use Lux.Prism,
    name: "PancakeSwap Position Tracker",
    description: "Tracks farming positions, APY and rewards on PancakeSwap",
    input_schema: %{
      type: :object,
      properties: %{
        wallet_address: %{type: :string, description: "Wallet address to track"},
        chain_id: %{type: :integer, description: "Chain ID (56=BSC)", default: 56}
      },
      required: ["wallet_address"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        positions: %{type: :array, description: "List of active positions"},
        total_value_usd: %{type: :string},
        pending_rewards: %{type: :string},
        status: %{type: :string}
      },
      required: ["status"]
    }

  import Lux.Python
  require Lux.Python
  require Logger

  def handler(input, _ctx) do
    input = Map.put_new(input, :chain_id, 56)
    Logger.info("PancakeSwap position tracking: #{input.wallet_address}")

    with {:ok, result} <- fetch_positions(input) do
      {:ok, result}
    end
  end

  defp fetch_positions(params) do
    python_result =
      python variables: %{
               wallet_address: params.wallet_address,
               chain_id: params.chain_id
             } do
        ~PY"""
        result = None
        try:
            from goat_plugins.pancakeswap import pancakeswap, PancakeswapPluginOptions
            from goat_wallets.evm import EVMWalletClient
            import asyncio

            async def run_positions():
                options = PancakeswapPluginOptions(chain_id=chain_id)
                plugin = pancakeswap(options)
                wallet = EVMWalletClient(chain_id=chain_id)

                res = await plugin.get_positions(wallet, {
                    "walletAddress": wallet_address
                })

                return {
                    "positions": res.get("positions", []),
                    "total_value_usd": str(res.get("totalValueUsd", "0")),
                    "pending_rewards": str(res.get("pendingRewards", "0")),
                    "status": "success"
                }

            result = asyncio.run(run_positions())
        except Exception as e:
            result = {"error": str(e)}
        result
        """
      end

    case python_result do
      %{"error" => error} -> {:error, error}
      %{"status" => _} = res -> {:ok, res}
    end
  end
end
