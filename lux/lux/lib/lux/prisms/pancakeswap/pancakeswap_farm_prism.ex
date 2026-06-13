defmodule Lux.Prisms.Pancakeswap.PancakeswapFarmPrism do
  @moduledoc """
  A prism for yield farming on PancakeSwap.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapFarmPrism.handler(%{
      ...>   action: "deposit",
      ...>   pool_id: 1,
      ...>   amount: "1000000000000000000",
      ...>   chain_id: 56
      ...> }, %{})
  """

  use Lux.Prism,
    name: "PancakeSwap Yield Farming",
    description: "Manages yield farming positions on PancakeSwap",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: deposit, withdraw, harvest",
          enum: ["deposit", "withdraw", "harvest"]
        },
        pool_id: %{type: :integer, description: "Farm pool ID"},
        amount: %{type: :string, description: "Amount in wei (not needed for harvest)"},
        chain_id: %{type: :integer, description: "Chain ID (56=BSC)", default: 56}
      },
      required: ["action", "pool_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        tx_hash: %{type: :string},
        rewards_claimed: %{type: :string},
        status: %{type: :string}
      },
      required: ["status"]
    }

  import Lux.Python
  require Lux.Python
  require Logger

  def handler(input, _ctx) do
    input = Map.put_new(input, :chain_id, 56)
    Logger.info("PancakeSwap farm action: #{input.action} pool_id=#{input.pool_id}")

    with {:ok, result} <- execute_farm_action(input) do
      {:ok, result}
    end
  end

  defp execute_farm_action(params) do
    python_result =
      python variables: %{
               action: params.action,
               pool_id: params.pool_id,
               amount: Map.get(params, :amount, "0"),
               chain_id: params.chain_id
             } do
        ~PY"""
        result = None
        try:
            from goat_plugins.pancakeswap import pancakeswap, PancakeswapPluginOptions
            from goat_wallets.evm import EVMWalletClient
            import asyncio

            async def run_farm():
                options = PancakeswapPluginOptions(chain_id=chain_id)
                plugin = pancakeswap(options)
                wallet = EVMWalletClient(chain_id=chain_id)

                if action == "deposit":
                    res = await plugin.farm_deposit(wallet, {"poolId": pool_id, "amount": amount})
                elif action == "withdraw":
                    res = await plugin.farm_withdraw(wallet, {"poolId": pool_id, "amount": amount})
                elif action == "harvest":
                    res = await plugin.farm_harvest(wallet, {"poolId": pool_id})
                else:
                    raise ValueError(f"Unknown action: {action}")

                return {
                    "tx_hash": res.get("txHash", ""),
                    "rewards_claimed": res.get("rewardsClaimed", "0"),
                    "status": "success"
                }

            result = asyncio.run(run_farm())
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
