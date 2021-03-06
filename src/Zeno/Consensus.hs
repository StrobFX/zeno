
module Zeno.Consensus
  ( module Zeno.Consensus.Types
  , Address
  , Collect
  , collectMajority
  , collectMember
  , collectMembers
  , collectThreshold
  , collectWith
  , majorityThreshold
  , runConsensus
  , startSeedNode
  , step
  , stepOptData
  , withConsensusNode
  , withConsensusRunnerContext
  , withRetry
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8

import Network.Ethereum.Crypto (Address)

import Zeno.Consensus.Frontend
import Zeno.Consensus.P2P
import Zeno.Consensus.Runner
import Zeno.Consensus.Types

import Zeno.Process
import Zeno.Prelude
import Zeno.Console


-- Node -----------------------------------------------------------------------

withConsensusNode :: ConsensusNetworkConfig -> Zeno (ConsensusNode ZenoRunnerBase) a -> Zeno () a
withConsensusNode netconf act = do
  withConsensusRunnerContext netconf do
    runner <- startConsensusRunner
    withContext (\(P2PNode node p2p) -> ConsensusNode node p2p runner) act

withConsensusRunnerContext :: ConsensusNetworkConfig -> Zeno P2PNode a -> Zeno () a
withConsensusRunnerContext CNC{..} act = do
  withNode netConf do
    p2p <- startP2P seeds
    node <- ask
    let runnerCtx = P2PNode node p2p
    withContext (const runnerCtx) act


startSeedNode :: NetworkConfig -> ConsoleArgs -> IO ()
startSeedNode nc consoleArgs = do
  let cnc = CNC [] nc
  runZeno defaultLog () do
    withConsole consoleArgs LevelDebug do
      withConsensusRunnerContext cnc $ threadDelay $ 2^62
