defmodule Lux.Prisms.Pancakeswap.PancakeswapSwapPrism do
  @moduledoc """
  A prism that executes token swaps on PancakeSwap.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapSwapPrism.handler(%{
      ...>   token_in: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
      ...>   token_out: "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56",
      ...>   amount_in: "1000000000000000000",
      ...>   chain_id: 56,
      ...>   slippage: 50
      ...> }, %{})
  """

  use Lux.Prism,
    name: "PancakeSwap Token Swap",
    description: "Executes token swaps on PancakeSwap DEX",
    input_schema: %{
      type: :object,
      properties: %{
        token_in: %{type: :string, description: "Input token address"},
        token_out: %{type: :string, description: "Output token address"},
        amount_in: %{type: :string, description: "Amount to swap (in wei)"},
        chain_id: %{type: :integer, description: "Chain ID (56=BSC, 1=ETH)", default: 56},
        slippage: %{type: :integer, description: "Slippage in basis points", default: 50}
      },
      required: ["token_in", "token_out", "amount_in"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        tx_hash: %{type: :string},
        amount_out: %{type: :string},
        status: %{type: :string}
      },
      required: ["tx_hash", "amount_out", "status"]
    }

  import Lux.Python
  require Lux.Python
  require Logger

  def handler(input, _ctx) do
    input = Map.put_new(input, :chain_id, 56)
    input = Map.put_new(input, :slippage, 50)

    Logger.info("PancakeSwap swap: #{input.amount_in} #{input.token_in} -> #{input.token_out}")

    with {:ok, result} <- execute_swap(input) do
      {:ok, result}
    end
  end

  defp execute_swap(params) do
    python_result =
      python variables: %{
               token_in: params.token_in,
               token_out: params.token_out,
               amount_in: params.amount_in,
               chain_id: params.chain_id,
               slippage: params.slippage
             } do
        ~PY"""
        result = None
        try:
            from goat_plugins.pancakeswap import pancakeswap, PancakeswapPluginOptions
            from goat_wallets.evm import EVMWalletClient
            import asyncio

            async def run_swap():
                options = PancakeswapPluginOptions(chain_id=chain_id)
                plugin = pancakeswap(options)
                wallet = EVMWalletClient(chain_id=chain_id)

                swap_result = await plugin.swap_tokens(wallet, {
                    "tokenIn": token_in,
                    "tokenOut": token_out,
                    "amount": amount_in,
                    "slippage": slippage
                })

                return {
                    "tx_hash": swap_result["txHash"],
                    "amount_out": swap_result["amountOut"],
                    "status": "success"
                }

            result = asyncio.run(run_swap())
        except Exception as e:
            result = {"error": str(e)}
        result
        """
      end

    case python_result do
      %{"error" => error} -> {:error, error}
      %{"tx_hash" => _, "amount_out" => _, "status" => _} = res -> {:ok, res}
    end
  end
end
