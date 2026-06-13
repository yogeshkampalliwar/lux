defmodule Lux.Prisms.Sushiswap.SushiswapBridgePrism do
  @moduledoc """
  Monitors SushiSwap cross-chain bridge (Stargate) operations.

  ## Example

      iex> Lux.Prisms.Sushiswap.SushiswapBridgePrism.run(%{
      ...>   action: "get_bridge_fee",
      ...>   src_chain_id: 56,
      ...>   dst_chain_id: 137,
      ...>   token: "USDC",
      ...>   amount: "1000000000000000000"
      ...> })
      {:ok, %{status: "success", fee_wei: "...", fee_usd: "..."}}
  """

  use Lux.Prism,
    name: "SushiSwap Bridge Monitor",
    description: "Monitors cross-chain bridge operations and fees via Stargate",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: get_bridge_fee | get_bridge_status | estimate_time",
          enum: ["get_bridge_fee", "get_bridge_status", "estimate_time"]
        },
        src_chain_id: %{type: :integer, description: "Source chain ID"},
        dst_chain_id: %{type: :integer, description: "Destination chain ID"},
        token: %{type: :string, description: "Token symbol: USDC, USDT, ETH"},
        amount: %{type: :string, description: "Amount in wei"},
        tx_hash: %{type: :string, description: "Bridge TX hash (for status check)"}
      },
      required: ["action", "src_chain_id", "dst_chain_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        fee_wei: %{type: :string},
        fee_usd: %{type: :string},
        estimated_time: %{type: :string},
        bridge_status: %{type: :string},
        src_chain: %{type: :string},
        dst_chain: %{type: :string}
      },
      required: ["status"]
    }

  import Lux.Python
  require Lux.Python

  @chain_names %{
    1     => "Ethereum",
    56    => "BSC",
    137   => "Polygon",
    42161 => "Arbitrum",
    10    => "Optimism",
    43114 => "Avalanche"
  }

  @rpcs %{
    1     => "https://eth.llamarpc.com",
    56    => "https://bsc-dataseed.binance.org/",
    137   => "https://polygon-rpc.com",
    42161 => "https://arb1.arbitrum.io/rpc"
  }

  # Stargate bridge contracts (used by SushiXSwap)
  @stargate_routers %{
    1     => "0x8731d54E9D02c286767d56ac03e8037C07e01e98",
    56    => "0x4a364f8c717cAAD9A442737Eb7b8A55cc6cf18D8",
    137   => "0x45A01E4e04F14f7A4a6702c74187c5F6222033cd",
    42161 => "0x53Bf833A5d6c4ddA888F69c22C88C9f356a41614"
  }

  def handler(input, _ctx) do
    action       = input[:action]       || input["action"]
    src_chain_id = input[:src_chain_id] || input["src_chain_id"]
    dst_chain_id = input[:dst_chain_id] || input["dst_chain_id"]
    token        = input[:token]        || input["token"] || "USDC"
    amount       = input[:amount]       || input["amount"] || "0"
    tx_hash      = input[:tx_hash]      || input["tx_hash"]
    rpc_url      = @rpcs[src_chain_id]  || @rpcs[56]
    src_router   = @stargate_routers[src_chain_id]
    src_name     = @chain_names[src_chain_id] || "Unknown"
    dst_name     = @chain_names[dst_chain_id] || "Unknown"

    with {:ok, result} <- execute_bridge_action(
           action, rpc_url, src_router,
           src_chain_id, dst_chain_id,
           token, amount, tx_hash,
           src_name, dst_name
         ) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_bridge_action(action, rpc_url, src_router, src_chain_id, dst_chain_id, token, amount, tx_hash, src_name, dst_name) do
    result =
      python variables: %{
        action:       action,
        rpc_url:      rpc_url,
        src_router:   src_router,
        src_chain_id: src_chain_id,
        dst_chain_id: dst_chain_id,
        token:        token,
        amount:       amount,
        tx_hash:      tx_hash,
        src_name:     src_name,
        dst_name:     dst_name
      } do
        ~PY"""
        from web3 import Web3

        w3 = Web3(Web3.HTTPProvider(rpc_url))

        # Stargate LayerZero chain IDs
        LZ_CHAIN_IDS = {
          1:     101,
          56:    102,
          137:   109,
          42161: 110,
          10:    111,
          43114: 106
        }

        # Average bridge times (minutes)
        BRIDGE_TIMES = {
          (1, 56):     "10-20 min",
          (1, 137):    "10-20 min",
          (1, 42161):  "10-20 min",
          (56, 137):   "10-15 min",
          (56, 42161): "10-15 min",
          (137, 56):   "10-15 min",
        }

        if action == "get_bridge_fee":
          # Stargate quoteLayerZeroFee ABI
          STARGATE_ABI = [{
            "inputs": [
              {"name": "_dstChainId",    "type": "uint16"},
              {"name": "_functionType",  "type": "uint8"},
              {"name": "_toAddress",     "type": "bytes"},
              {"name": "_transferAndCallPayload", "type": "bytes"},
              {"name": "_lzTxParams",    "type": "tuple",
               "components": [
                 {"name": "dstGasForCall",    "type": "uint256"},
                 {"name": "dstNativeAmount",  "type": "uint256"},
                 {"name": "dstNativeAddr",    "type": "bytes"}
               ]}
            ],
            "name": "quoteLayerZeroFee",
            "outputs": [
              {"name": "", "type": "uint256"},
              {"name": "", "type": "uint256"}
            ],
            "stateMutability": "view",
            "type": "function"
          }]

          try:
            if src_router and w3.is_connected():
              router = w3.eth.contract(
                address=Web3.to_checksum_address(src_router),
                abi=STARGATE_ABI
              )
              lz_dst = LZ_CHAIN_IDS.get(dst_chain_id, 109)
              fee, _ = router.functions.quoteLayerZeroFee(
                lz_dst, 1,
                b"\\x00" * 20,
                b"",
                (0, 0, b"\\x00")
              ).call()
              fee_usd = float(fee) / 1e18 * 300  # rough BNB/ETH price
              {
                "status":     "success",
                "fee_wei":    str(fee),
                "fee_usd":    f"~${fee_usd:.4f}",
                "src_chain":  src_name,
                "dst_chain":  dst_name,
                "token":      token
              }
            else:
              {
                "status":    "success",
                "fee_wei":   "0",
                "fee_usd":   "~$0.10-$0.50 (estimate)",
                "src_chain": src_name,
                "dst_chain": dst_name,
                "note":      "RPC unavailable — showing estimate"
              }
          except Exception as e:
            {
              "status":    "success",
              "fee_wei":   "0",
              "fee_usd":   "~$0.10-$0.50 (estimate)",
              "src_chain": src_name,
              "dst_chain": dst_name,
              "note":      str(e)
            }

        elif action == "estimate_time":
          bridge_time = BRIDGE_TIMES.get(
            (src_chain_id, dst_chain_id),
            "10-30 min"
          )
          {
            "status":         "success",
            "estimated_time": bridge_time,
            "src_chain":      src_name,
            "dst_chain":      dst_name
          }

        elif action == "get_bridge_status":
          if not tx_hash:
            {"error": "tx_hash required for status check"}
          else:
            try:
              receipt = w3.eth.get_transaction_receipt(tx_hash)
              status  = "completed" if receipt.status == 1 else "failed"
              {
                "status":        "success",
                "bridge_status": status,
                "tx_hash":       tx_hash,
                "gas_used":      receipt.gasUsed,
                "src_chain":     src_name,
                "dst_chain":     dst_name
              }
            except Exception as e:
              {"error": f"Could not fetch TX status: {str(e)}"}
        else:
          {"error": f"Unknown action: {action}"}
        """
      end

    case result do
      %{"error" => e}          -> {:error, e}
      %{"status" => "success"} = r -> {:ok, r}
      _ -> {:error, "Unexpected response"}
    end
  end
end
