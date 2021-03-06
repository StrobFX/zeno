{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedLists #-}

module TestConsensusRunner where

import TestUtils

import Control.Monad.Reader
import Control.Monad.State

import qualified Data.ByteString.Lazy as BSL
import Data.List (uncons)
import qualified Data.Set as Set
import qualified Data.Map as Map

import Network.Ethereum.Crypto

import UnliftIO

import Zeno.Process
import Zeno.Consensus
import Zeno.Consensus.P2P
import Zeno.Consensus.Runner
import Zeno.Consensus.Step
import Zeno.Prelude
import Zeno.Console


unit_test_sync :: IO ()
unit_test_sync = do
  [step0, step1] <- testSteps 0 idents2

  void $ runTestNode 2 do
    flip runStateT (newNodeStates 2 emptyRunnerState) do
      node "0:0" do
        newStep stepId0 $ createStep step0 $ Just 0
      node "1:1" do
        newStep stepId0 $ createStep step1 $ Just 1

      node "0:0" $ getMsg >>= onMessage
      node "1:1" $ getMsg >>= onMessage
      
      dumpInv step0 >>= (@?= targetInv0)
      dumpInv step1 >>= (@?= targetInv0)

      lift $ use _2 >>= (@?= mempty)

      node "0:0" $ use _delays >>= mapM_ unRunnerAction
      node "1:1" $ use _delays >>= mapM_ unRunnerAction

    msgMap <- use _2 <&> over (each . each) (decodeAuthenticated step0 . fmap (BSL.drop 13))
    msgMap @?=
      Map.fromList [ ("0:0", [Right (StepMessage 3 0 mempty)])
                   , ("1:1", [Right (StepMessage 3 0 mempty)])
                   ]

stepId0 = StepId minBound 0 0
stepId1 = StepId minBound 1 0

unit_test_miss_cache :: IO ()
unit_test_miss_cache = do
  [step0, step1] <- testSteps 0 idents2

  void $ runTestNode 2 do
    flip runStateT (newNodeStates 2 emptyRunnerState) do

      node "0:0" $ newStep stepId0 $ createStep step0 $ Just 0
      node "1:1" do
        getMsg >>= onMessage
        use (_missCache . to length) >>= (@?= 1)
        newStep stepId0 $ createStep step1 $ Just 1
        use (_missCache . to length) >>= (@?= 0)
      dumpInv step1 >>= (@?= targetInv0)


data RoundState
  = INIT
  | STEP Int (Step Int) (Inventory Int)
  | DONE
  | TIMEOUT
  deriving (Eq)

instance Eq (Step i) where
  s == s1 = stepId s == stepId s1

instance Show RoundState where
  show INIT = "INIT"
  show DONE = "DONE"
  show TIMEOUT = "TIMEOUT"
  show (STEP sid Step{..} inv) = "STEP %i %i" % (sid, length inv)



unit_test_round_ideal :: IO ()
unit_test_round_ideal = do

  let nnodes = 3
  let nsteps = 3
  allSteps <- forM [0..nsteps-1] \i -> testSteps i (take nnodes identsInf)

  void $ runTestNode nnodes do
    flip runStateT (newNodeStates nnodes emptyRunnerState) do

      res <- do

        -- WHILE loop
        fix1 (replicate nnodes INIT) \go r -> do

          -- for each node
          r' <- forM (zip [0..] r) \(n, s) -> do
            node (testNodeId n) do
              case s of
                DONE -> pure DONE
                TIMEOUT -> pure TIMEOUT
                INIT -> do
                  let step = allSteps !! 0 !! n
                  let stepId = StepId minBound 0 0
                  newStep stepId $ createStep step $ Just n
                  inv <- snd <$> readIORef (ioInv step)
                  pure $ STEP 0 step inv

                STEP stepNum stepData inv -> do
                  getMsgMaybe >>= mapM_ onMessage
                  inv <- snd <$> readIORef (ioInv stepData)
                  if | length inv < nnodes -> pure $ STEP stepNum stepData inv
                     | stepNum == nsteps-1 -> pure DONE
                     | otherwise -> do
                         let step = allSteps !! (stepNum+1) !! n
                         let stepId = StepId minBound (fromIntegral $ stepNum+1) 0
                         newStep stepId $ createStep step $ Just n
                         inv <- snd <$> readIORef (ioInv step)
                         pure $ STEP (stepNum+1) step inv

          mboxes <- lift $ use _mboxes
          if | (r == r' && length mboxes == 0) -> pure r'
             | r == replicate nnodes DONE -> pure r'
             | otherwise -> go r'

      res @?= replicate nnodes DONE


identsInf = map deriveEthIdent $ drop 1 [minBound..]
idents2 = take 2 identsInf

targetInv0 = (3, inv) where
  inv = [ ("0x897df33a7b3c62ade01e22c13d48f98124b4480f", 1)
        , ("0xdc5b20847f43d67928f49cd4f85d696b5a7617b5", 0)
        ]


-- | Get inventory without signatures
dumpInv :: MonadIO m => Step i -> m (PackedInteger, [(Address, i)])
dumpInv step = do
  (mask, invMap) <- readIORef $ ioInv step
  pure $ (mask, over (each . _2) snd $ Map.toList invMap)


testSteps :: MonadIO m => Int -> [EthIdent] -> m [Step Int]
testSteps stepNum idents = do
  let members = ethAddress <$> idents
      membersSet = Set.fromList members
      stepId = StepId minBound (fromIntegral stepNum) 0
      yield inv = pure ()
  forM idents \ident -> do
    ioInv <- newIORef (0, mempty)
    pure Step{..}
