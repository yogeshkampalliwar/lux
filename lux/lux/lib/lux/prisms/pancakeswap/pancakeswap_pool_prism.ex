defmodule Lux.Prisms.Pancakeswap.PancakeswapPoolPrism do
  @moduledoc """
  A prism for managing liquidity pools on PancakeSwap.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapPoolPrism.handler(%{
      ...>   action: "add_liquidity",
      ...>   token_a: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
      ...>   token_b: "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56",
      ...>   amount_a: "1000000000000000000",
      ...>   amount_b: "500000000000000000",
      ...>   chain_id: 56
      ...> }, %{})
  """

  use Lux.Prism,
    name: "PancakeSwap Pool Management",
    description: "Manages liquidity pool positions on PancakeSwap",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: add_liquidity, remove_liquidity, get_pool_info",
          enum: ["add_liquidity", "remove_liquidity", "get_pool_info"]
        },
        token_a: %{type: :string, description: "Token A address"},
        token_b: %{type: :string, description: "Token B address"},
        amount_a: %{type: :string, description: "Amount of token A in wei"},
        amount_b: %{type: :string, description: "Amount of token B in wei"},
        lp_amount: %{type: :string, description: "LP token amount for removal"},
        chain_id: %{type: :integer, description: "Chain ID (56=BSC)", default: 56}
      },
      required: ["action", "token_a", "token_b"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        tx_hash: %{type: :string},
        lp_tokens: %{type: :string},
        pool_share: %{type: :string},
        apy: %{type: :string},
        status: %{type: :string}
      },
      required: ["status"]
    }

  import Lux.Python
  require Lux.Python
  require Logger

  def handler(input, _ctx) do
    input = Map.put_new(input, :chain_id, 56)
    Logger.info("PancakeSwap pool action: #{input.action}")

    with {:ok, result} <- execute_pool_action(input) do
      {:ok, result}
    end
  end

  defp execute_pool_action(params) do
    python_result =
      python variables: %{
               action: params.action,
               token_a: params.token_a,
               token_b: params.token_b,
               amount_a: Map.get(params, :amount_a, "0"),
               amount_b: Map.get(params, :amount_b, "0"),
               lp_amount: Map.get(params, :lp_amount, "0"),
               chain_id: params.chain_id
             } do
        ~PY"""
        result = None
        try:
            from goat_plugins.pancakeswap import pancakeswap, PancakeswapPluginOptions
            from goat_wallets.evm import EVMWalletClient
            import asyncio

            async def run_pool():
                options = PancakeswapPluginOptions(chain_id=chain_id)
                plugin = pancakeswap(options)
                wallet = EVMWalletClient(chain_id=chain_id)

                if action == "add_liquidity":
                    res = await plugin.add_liquidity(wallet, {
                        "tokenA": token_a,
                        "tokenB": token_b,
                        "amountA": amount_a,
                        "amountB": amount_b
                    })
                    return {
                        "tx_hash": res.get("txHash", ""),
                        "lp_tokens": res.get("lpTokens", "0"),
                        "pool_share": res.get("poolShare", "0"),
                        "status": "success"
                    }
                elif action == "remove_liquidity":
                    res = await plugin.remove_liquidity(wallet, {
                        "tokenA": token_a,
                        "tokenB": token_b,
                        "lpAmount": lp_amount
                    })
                    return {
                        "tx_hash": res.get("txHash", ""),
                        "status": "success"
                    }
                elif action == "get_pool_info":
                    res = await plugin.get_pool_info(wallet, {
                        "tokenA": token_a,
                        "tokenB": token_b
                    })
                    return {
                        "apy": str(res.get("apy", "0")),
                        "pool_share": str(res.get("poolShare", "0")),
                        "lp_tokens": str(res.get("lpTokens", "0")),
                        "status": "success"
                    }

            result = asyncio.run(run_pool())
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
