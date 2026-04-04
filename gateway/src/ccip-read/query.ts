import { drpc } from 'evm-providers'
import { type Hex, createPublicClient, http } from 'viem'
import {
  arbitrum,
  arbitrumSepolia,
  arcTestnet,
  base,
  baseSepolia,
  celo,
  celoSepolia,
  linea,
  lineaSepolia,
  optimism,
  optimismSepolia,
  polygon,
  polygonAmoy,
  scroll,
  scrollSepolia,
  worldchain,
  worldchainSepolia,
} from 'viem/chains'
import { decodeFunctionData } from 'viem/utils'

import { type Env, envVar } from '../env'
import { dnsDecodeName, resolverAbi } from './utils'

const supportedChains = [
  arcTestnet,
  arbitrum,
  arbitrumSepolia,
  base,
  baseSepolia,
  celo,
  celoSepolia,
  linea,
  lineaSepolia,
  optimism,
  optimismSepolia,
  polygon,
  polygonAmoy,
  scroll,
  scrollSepolia,
  worldchain,
  worldchainSepolia,
]

type HandleQueryArgs = {
  dnsEncodedName: Hex
  encodedResolveCall: Hex
  targetChainId: bigint
  targetRegistryAddress: Hex
  env: Env
}

export async function handleQuery({
  dnsEncodedName,
  encodedResolveCall,
  targetChainId,
  targetRegistryAddress,
  env,
}: HandleQueryArgs) {
  const name = dnsDecodeName(dnsEncodedName)

  // Decode the internal resolve call like addr(), text() or contenthash()
  const { functionName, args } = decodeFunctionData({
    abi: resolverAbi,
    data: encodedResolveCall,
  })

  const chain = supportedChains.find(
    (chain) => BigInt(chain.id) === targetChainId
  )

  if (!chain) {
    console.error(`Unsupported chain ${targetChainId} for ${name}`)
    return '0x' as const
  }

  const DRPC_API_KEY = envVar('DRPC_API_KEY', env)

  const l2Client = createPublicClient({
    chain,
    transport: http(
      // World subsidizes RPC usage, so we'll use those endpoints for mainnet and testnet
      chain.id === worldchainSepolia.id
        ? 'https://worldchain-sepolia.g.alchemy.com/public'
        : chain.id === worldchain.id
          ? 'https://worldchain-mainnet.g.alchemy.com/public'
          : chain.id === arcTestnet.id
            ? `https://lb.drpc.live/arc-testnet/${DRPC_API_KEY}`
            : drpc(chain.id, DRPC_API_KEY)
    ),
  })

  console.log({
    targetChainId,
    targetRegistryAddress,
    name,
    functionName,
    args,
  })

  return l2Client.readContract({
    address: targetRegistryAddress,
    abi: [resolverAbi[1]],
    functionName: 'resolve',
    args: [dnsEncodedName, encodedResolveCall],
  })
}
