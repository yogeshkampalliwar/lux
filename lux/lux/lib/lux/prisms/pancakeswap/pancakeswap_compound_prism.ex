defmodule Lux.Prisms.Pancakeswap.PancakeswapCompoundPrism do
  @moduledoc """
  A prism for auto-compounding rewards on PancakeSwap.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapCompoundPrism.handler(%{
      ...>   pool_id: 1,
      ...>   wallet_address: "0x1234567890abcdef",
      ...>   slippage: 50,
      ...>   chain_id: 56
      ...> }, %{})
  """

  use Lux.Prism,
    name: "PancakeSwap Auto Compounder",
    description: "Auto-compounds CAKE rewards back into farming positions",
    input_schema: %{
      type: :object,
      properties: %{
        pool_id: %{type: :integer, description: "Farm pool ID to compound"},
        wallet_address: %{type: :string, description: "Wallet address"},
        slippage: %{type: :integer, description: "Slippage in basis points", default: 50},
        chain_id: %{type: :integer, description: "Chain ID (56=BSC)", default: 56}
      },
      required: ["pool_id", "wallet_address"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        tx_hash: %{type: :string},
        compounded_amount: %{type: :string},
        new_position: %{type: :string},
        status: %{type: :string}
      },
      required: ["status"]
    }

  import Lux.Python
  require Lux.Python
  require Logger

  def handler(input, _ctx) do
    input = Map.put_new(input, :chain_id, 56)
    input = Map.put_new(input, :slippage, 50)
    Logger.info("PancakeSwap auto-compound pool_id=#{input.pool_id}")

    with {:ok, result} <- execute_compound(input) do
      {:ok, result}
    end
  end

  defp execute_compound(params) do
    python_result =
      python variables: %{
               pool_id: params.pool_id,
               wallet_address: params.wallet_address,
               slippage: params.slippage,
               chain_id: params.chain_id
             } do
        ~PY"""
        result = None
        try:
            from goat_plugins.pancakeswap import pancakeswap, PancakeswapPluginOptions
            from goat_wallets.evm import EVMWalletClient
            import asyncio

            async def run_compound():
                options = PancakeswapPluginOptions(chain_id=chain_id)
                plugin = pancakeswap(options)
                wallet = EVMWalletClient(chain_id=chain_id)

                # Step 1: Harvest rewards
                harvest = await plugin.farm_harvest(wallet, {"poolId": pool_id})

                # Step 2: Swap CAKE rewards to LP tokens
                compound = await plugin.compound_rewards(wallet, {
                    "poolId": pool_id,
                    "walletAddress": wallet_address,
                    "slippage": slippage
                })

                return {
                    "tx_hash": compound.get("txHash", ""),
                    "compounded_amount": str(compound.get("compoundedAmount", "0")),
                    "new_position": str(compound.get("newPosition", "0")),
                    "status": "success"
                }

            result = asyncio.run(run_compound())
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
