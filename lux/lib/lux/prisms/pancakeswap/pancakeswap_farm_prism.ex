defmodule Lux.Prisms.Pancakeswap.PancakeswapFarmPrism do
  @moduledoc """
  A prism for yield farming on PancakeSwap MasterChef V2.

  Handles LP token approval automatically before deposit.
  Fetches LP token address from pool_id via poolInfo.

  ## Example

      iex> Lux.Prisms.Pancakeswap.PancakeswapFarmPrism.handler(%{
      ...>   action: "deposit",
      ...>   pool_id: 1,
      ...>   amount: "1000000000000000000",
      ...>   chain_id: 56
      ...> }, %{})

  Reads config:
  - :pancakeswap_private_key - wallet private key
  """

  use Lux.Prism,
    name: "PancakeSwap Yield Farming",
    description: "Manages yield farming on PancakeSwap MasterChef V2 with auto LP token approval",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: deposit, withdraw, harvest",
          enum: ["deposit", "withdraw", "harvest"]
        },
        pool_id: %{type: :integer, description: "MasterChef pool ID (pid)"},
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

  alias Lux.Config

  @masterchef_v2 "0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652"

  @masterchef_abi [
    %{
      "name" => "deposit",
      "type" => "function",
      "inputs" => [
        %{"name" => "_pid", "type" => "uint256"},
        %{"name" => "_amount", "type" => "uint256"}
      ],
      "outputs" => []
    },
    %{
      "name" => "withdraw",
      "type" => "function",
      "inputs" => [
        %{"name" => "_pid", "type" => "uint256"},
        %{"name" => "_amount", "type" => "uint256"}
      ],
      "outputs" => []
    },
    %{
      "name" => "pendingCake",
      "type" => "function",
      "inputs" => [
        %{"name" => "_pid", "type" => "uint256"},
        %{"name" => "_user", "type" => "address"}
      ],
      "outputs" => [%{"name" => "", "type" => "uint256"}]
    },
    %{
      "name" => "poolInfo",
      "type" => "function",
      "inputs" => [%{"name" => "_pid", "type" => "uint256"}],
      "outputs" => [
        %{"name" => "lpToken", "type" => "address"},
        %{"name" => "allocPoint", "type" => "uint256"},
        %{"name" => "lastRewardBlock", "type" => "uint256"},
        %{"name" => "accCakePerShare", "type" => "uint256"}
      ]
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

    with {:ok, private_key} <- get_private_key(),
         {:ok, %{"success" => true}} <- Lux.Python.import_package("web3"),
         {:ok, result} <- execute_farm_action(private_key, input) do
      {:ok, result}
    else
      {:error, :missing_private_key} ->
        {:error, "PancakeSwap private key is not configured"}
      {:ok, %{"success" => false, "error" => error}} ->
        {:error, "Failed to import web3: #{error}"}
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

  defp execute_farm_action(private_key, params) do
    python_result =
      python variables: %{
               private_key: private_key,
               action: params.action,
               pool_id: params.pool_id,
               amount: Map.get(params, :amount, "0"),
               masterchef_address: @masterchef_v2,
               masterchef_abi: Jason.encode!(@masterchef_abi),
               erc20_abi: Jason.encode!(@erc20_abi)
             } do
        ~PY"""
        result = None
        try:
            from web3 import Web3
            import json

            w3 = Web3(Web3.HTTPProvider("https://bsc-dataseed.binance.org/"))
            account = w3.eth.account.from_key(private_key)
            masterchef_abi = json.loads(masterchef_abi)
            erc20_abi = json.loads(erc20_abi)

            masterchef = w3.eth.contract(
                address=Web3.to_checksum_address(masterchef_address),
                abi=masterchef_abi
            )

            # Get pending CAKE rewards
            pending = masterchef.functions.pendingCake(
                pool_id, account.address
            ).call()

            # For deposit - get LP token address and approve
            if action == "deposit":
                pool_info = masterchef.functions.poolInfo(pool_id).call()
                lp_token_address = pool_info[0]

                lp_token = w3.eth.contract(
                    address=Web3.to_checksum_address(lp_token_address),
                    abi=erc20_abi
                )

                allowance = lp_token.functions.allowance(
                    account.address,
                    Web3.to_checksum_address(masterchef_address)
                ).call()

                if allowance < int(amount):
                    approve_tx = lp_token.functions.approve(
                        Web3.to_checksum_address(masterchef_address),
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

                tx = masterchef.functions.deposit(
                    pool_id, int(amount)
                ).build_transaction({
                    "from": account.address,
                    "nonce": w3.eth.get_transaction_count(account.address),
                    "gas": 300000,
                    "gasPrice": w3.eth.gas_price
                })

            elif action == "withdraw":
                tx = masterchef.functions.withdraw(
                    pool_id, int(amount)
                ).build_transaction({
                    "from": account.address,
                    "nonce": w3.eth.get_transaction_count(account.address),
                    "gas": 300000,
                    "gasPrice": w3.eth.gas_price
                })

            elif action == "harvest":
                tx = masterchef.functions.deposit(
                    pool_id, 0
                ).build_transaction({
                    "from": account.address,
                    "nonce": w3.eth.get_transaction_count(account.address),
                    "gas": 200000,
                    "gasPrice": w3.eth.gas_price
                })

            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

            result = {
                "tx_hash": tx_hash.hex(),
                "rewards_claimed": str(pending),
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
