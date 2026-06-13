defmodule Lux.Prisms.Pancakeswap.PancakeswapSwapPrism do
  @moduledoc """
  A prism that executes token swaps on PancakeSwap V2.

  Uses Router V2 swapExactTokensForTokens directly via web3.py.
  Handles ERC20 token approval automatically before swap.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapSwapPrism.handler(%{
      ...>   token_in: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
      ...>   token_out: "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56",
      ...>   amount_in: "1000000000000000000",
      ...>   chain_id: 56
      ...> }, %{})
  """

  use Lux.Prism,
    name: "PancakeSwap V2 Token Swap",
    description: "Executes token swaps on PancakeSwap V2 with auto token approval",
    input_schema: %{
      type: :object,
      properties: %{
        token_in: %{type: :string, description: "Input token address"},
        token_out: %{type: :string, description: "Output token address"},
        amount_in: %{type: :string, description: "Amount in wei"},
        slippage: %{type: :integer, description: "Slippage in bps", default: 50},
        chain_id: %{type: :integer, description: "Chain ID", default: 56}
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

  alias Lux.Config

  @router_v2 "0x10ED43C718714eb63d5aA57B78B54704E256024E"
  @bsc_rpc   "https://bsc-dataseed.binance.org/"

  @router_abi [
    %{
      "name" => "swapExactTokensForTokens",
      "type" => "function",
      "inputs" => [
        %{"name" => "amountIn", "type" => "uint256"},
        %{"name" => "amountOutMin", "type" => "uint256"},
        %{"name" => "path", "type" => "address[]"},
        %{"name" => "to", "type" => "address"},
        %{"name" => "deadline", "type" => "uint256"}
      ],
      "outputs" => [%{"name" => "amounts", "type" => "uint256[]"}]
    },
    %{
      "name" => "getAmountsOut",
      "type" => "function",
      "inputs" => [
        %{"name" => "amountIn", "type" => "uint256"},
        %{"name" => "path", "type" => "address[]"}
      ],
      "outputs" => [%{"name" => "amounts", "type" => "uint256[]"}]
    }
  ]

  @erc20_abi [
    %{
      "name" => "approve",
      "type" => "function",
      "inputs" => [
        %{"name" => "spender", "type" => "address"},
        %{"name" => "amount", "type" => "uint256"}
      ],
      "outputs" => [%{"name" => "", "type" => "bool"}]
    },
    %{
      "name" => "allowance",
      "type" => "function",
      "inputs" => [
        %{"name" => "owner", "type" => "address"},
        %{"name" => "spender", "type" => "address"}
      ],
      "outputs" => [%{"name" => "", "type" => "uint256"}]
    }
  ]

  def handler(input, _ctx) do
    input = Map.put_new(input, :chain_id, 56)
    input = Map.put_new(input, :slippage, 50)

    with {:ok, private_key} <- get_private_key(),
         {:ok, %{"success" => true}} <- Lux.Python.import_package("web3"),
         {:ok, result} <- execute_swap(private_key, input) do
      {:ok, result}
    else
      {:error, :missing_private_key} ->
        {:error, "Private key not configured"}
      {:ok, %{"success" => false, "error" => error}} ->
        {:error, "web3 import failed: #{error}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_private_key do
    case Config.pancakeswap_private_key() do
      nil -> {:error, :missing_private_key}
      key -> {:ok, key}
    end
  rescue
    _ -> {:error, :missing_private_key}
  end

  defp execute_swap(private_key, params) do
    python_result =
      python variables: %{
               private_key: private_key,
               token_in: params.token_in,
               token_out: params.token_out,
               amount_in: params.amount_in,
               slippage: params.slippage,
               router_address: @router_v2,
               rpc_url: @bsc_rpc,
               router_abi: Jason.encode!(@router_abi),
               erc20_abi: Jason.encode!(@erc20_abi)
             } do
        ~PY"""
        result = None
        try:
            from web3 import Web3
            from datetime import datetime, timedelta
            import json

            w3 = Web3(Web3.HTTPProvider(rpc_url))
            account = w3.eth.account.from_key(private_key)
            router_abi = json.loads(router_abi)
            erc20_abi = json.loads(erc20_abi)

            router = w3.eth.contract(
                address=Web3.to_checksum_address(router_address),
                abi=router_abi
            )

            token_in_address = Web3.to_checksum_address(token_in)
            token_out_address = Web3.to_checksum_address(token_out)
            router_address_checksum = Web3.to_checksum_address(router_address)

            # Check and set token approval
            token_contract = w3.eth.contract(
                address=token_in_address,
                abi=erc20_abi
            )

            allowance = token_contract.functions.allowance(
                account.address,
                router_address_checksum
            ).call()

            if allowance < int(amount_in):
                approve_tx = token_contract.functions.approve(
                    router_address_checksum,
                    2**256 - 1
                ).build_transaction({
                    "from": account.address,
                    "nonce": w3.eth.get_transaction_count(account.address),
                    "gas": 100000,
                    "gasPrice": w3.eth.gas_price
                })
                signed_approve = account.sign_transaction(approve_tx)
                approve_hash = w3.eth.send_raw_transaction(signed_approve.raw_transaction)
                w3.eth.wait_for_transaction_receipt(approve_hash)

            path = [token_in_address, token_out_address]
            amounts_out = router.functions.getAmountsOut(int(amount_in), path).call()
            amount_out_min = int(amounts_out[-1] * (1 - slippage / 10000))
            deadline = int((datetime.now() + timedelta(minutes=20)).timestamp())

            tx = router.functions.swapExactTokensForTokens(
                int(amount_in),
                amount_out_min,
                path,
                account.address,
                deadline
            ).build_transaction({
                "from": account.address,
                "nonce": w3.eth.get_transaction_count(account.address),
                "gas": 250000,
                "gasPrice": w3.eth.gas_price
            })

            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

            result = {
                "tx_hash": tx_hash.hex(),
                "amount_out": str(amounts_out[-1]),
                "status": "success" if receipt.status == 1 else "failed"
            }
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
