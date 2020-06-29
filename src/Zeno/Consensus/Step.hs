{-# LANGUAGE PartialTypeSignatures #-}

module Zeno.Consensus.Step where

-- This module deals with exchanging messages and building inventory.
-- The entry point is `runStep`. Each step has a topic, and each member
-- will provide an input. Messages are exhanged until all participants
-- have a full inventory or the step is cancelled.

import           Control.DeepSeq
import           Control.Monad
import           Control.Monad.STM (orElse)
import           Control.Monad.Skeleton

import           Data.Bits
import           Data.Serialize
import qualified Data.Map.Strict as Map
import           Data.Map.Merge.Strict
import qualified Data.Set as Set
import           Data.Typeable

import           GHC.Generics (Generic)

import           Network.Ethereum.Crypto

import           Zeno.Process
import           Zeno.Consensus.P2P
import           Zeno.Consensus.Types
import           Zeno.Console
import           Zeno.Prelude

import           UnliftIO
import           UnliftIO.Concurrent


inventoryQueryInterval :: Int
inventoryQueryInterval = 200 * 1000

data Step i = Step
  { ioInv      :: IORef (PackedInteger, Inventory i)
  , members    :: [Address]
  , membersSet :: Set Address
  , roundId    :: RoundId
  , stepNum    :: StepNum
  , ident      :: EthIdent
  , yield      :: Inventory i -> IO ()
  }

type StepBase m = (MonadLogger m, MonadIO m)


createStep :: (BallotData i, StepBase m)
           => ConsensusParams -> Step i -> Maybe i -> ConsensusStep m Void
createStep cparams step@Step{..} = runStepSkel step . fmap signObj
  where
  signObj obj =
    let ConsensusParams{ident' = EthIdent sk myAddr, ..} = cparams
        sighash = getBallotSighash obj
        mySig = unsafePerformIO $ signIO sk sighash
     in Ballot myAddr mySig obj


runStepSkel :: (BallotData i, StepBase m) => Step i -> Maybe (Ballot i) -> ConsensusStep m Void
runStepSkel step@Step{..} mballot = do
  forM_ mballot \(Ballot myAddr sig obj) -> do
    onInventoryData step True $ Map.singleton myAddr (sig, obj)
  bone $ RegisterTickFree inventoryQueryInterval
  buildInventoryLoop step

buildInventoryLoop :: StepBase m => BallotData i => Step i -> ConsensusStep m Void
buildInventoryLoop step@Step{..} = do
  forever do
    fix1 mempty $ \go !idxs -> do
      bone ReceiveFree >>=
        \case
          StepNewPeer peer -> onNewPeer step peer
          StepTick -> do
            sendInventoryQueries step $ Map.toList idxs
            bone $ RegisterTickFree inventoryQueryInterval
          StepData msg -> msg &
            decodeAuthenticated step
               \peer (StepMessage theirIdx theirReq theirData) -> do
                 onInventoryData step False theirData
                 onInventoryRequest step peer theirReq
                 go $ Map.insert peer theirIdx idxs

onNewPeer :: (BallotData i, StepBase m) => Step i -> NodeId -> ConsensusStep m ()
onNewPeer Step{..} peer = do
  (idx, inv) <- readIORef ioInv
  let msg = StepMessage idx 0 mempty
  sendAuthenticated Step{..} [peer] msg

onInventoryRequest :: StepBase m => BallotData i => Step i -> NodeId -> PackedInteger -> ConsensusStep m ()
onInventoryRequest _ _ 0 = pure ()
onInventoryRequest step@Step{..} peer theirReq = do
  (myIdx, inv) <- readIORef ioInv
  let subset = getInventorySubset theirReq members inv
  sendAuthenticated step [peer] $ StepMessage myIdx 0 subset


onInventoryData :: (BallotData i, StepBase m) => Step i -> Bool -> Inventory i -> ConsensusStep m ()
onInventoryData _ _ theirInv | Map.null theirInv = pure ()
onInventoryData step@Step{..} forwardInv theirInv = do

  let theirIdx = inventoryIndex members theirInv
  (oldIdx, oldInv) <- readIORef ioInv

  unless (0 == theirIdx .&. complement oldIdx) do

    case mergeInventory membersSet oldInv theirInv of
      Left s -> logWarn s

      Right newInv -> do
        let newIdx = theirIdx .|. oldIdx
        writeIORef ioInv (newIdx, newInv)

        liftIO $ yield newInv
        peers <- bone GetPeersFree
        let fwdInv = if forwardInv then newInv else mempty
        sendAuthenticated step peers $ StepMessage newIdx 0 fwdInv


mergeInventory :: BallotData i => Set Address -> Inventory i -> Inventory i -> Either String (Inventory i)
mergeInventory membersSet ours theirs = do
  mergeA preserveMissing
         (traverseMissing validateNew)
         (zipWithAMatched validateExisting)
         ours theirs
  where
  validateNew addr (sig, val) = do
    let sighash = getBallotSighash val
    when (Set.notMember addr membersSet) do
      throwError "Got ballot data for non member"
    let r = unsafePerformIO $ recoverAddr sighash sig
    when (r /= addr) do
      throwError "Got ballot data with invalid signature"
    pure (sig, val)
    
  -- We shouldn't be receiving data that we already have for a key, ever, ideally.
  -- If anything, maybe we should flag the sender.
  -- Currently, this will no be called since we compare the calculated indexes
  -- before called mergeInventory
  validateExisting _ ours _ = pure ours


sendInventoryQueries :: (BallotData i, StepBase m) => Step i -> [(NodeId, PackedInteger)] -> ConsensusStep m ()
sendInventoryQueries step@Step{..} idxs = do
  (myIdx, inv) <- readIORef ioInv
  let ordered = prioritiseRemoteInventory members inv idxs
      queries = dedupeInventoryQueries ordered
  forM_ queries \(peer, wanted) ->
    sendAuthenticated step [peer] $ StepMessage myIdx wanted mempty

--------------------------------------------------------------------------------
-- | Message authentication
--------------------------------------------------------------------------------

-- This thing is a bit terrible. It would be easy to make a mistake using it.
getBallotSighash :: BallotData a => a -> Bytes32
getBallotSighash obj = do
  case cast obj of
    Just b -> b
    Nothing -> sha3b $ encode obj

getMessageSigHash :: BallotData i => Step i -> (Maybe StepNum, StepMessage i) -> Bytes32
getMessageSigHash Step{..} obj = sha3b $ encode (roundId, stepNum, obj)

sendAuthenticated :: (BallotData i, StepBase m)
                  => Step i -> [NodeId] -> StepMessage i -> ConsensusStep m ()
sendAuthenticated Step{..} peers obj = do
  let EthIdent{..} = ident
  let payload = (Just stepNum, obj)
  let sighash = getMessageSigHash Step{..} payload
  sig <- signIO ethSecKey sighash
  forM_ peers $ \peer -> do
    bone $ SendRemoteFree peer (sig, payload)


-- TODO: Track who sends bad data
decodeAuthenticated
  :: (BallotData i, StepBase m)
  => Step i -> (NodeId -> StepMessage i -> ConsensusStep m ())
  -> RemoteMessage ByteString -> ConsensusStep m ()
decodeAuthenticated step@Step{..} act (RemoteMessage nodeId bs) = do
  forM_ (decode bs) \wsm -> do
    let WrappedStepMessage theirSig sn obj = wsm
    let sighash = getMessageSigHash step (sn, obj)
    addr <- recoverAddr sighash theirSig
    if elem addr members
       then act nodeId obj
       else logWarn $ "Not member or wrong step: " ++ show addr

--------------------------------------------------------------------------------
-- | Pure functions for inventory building
--------------------------------------------------------------------------------

-- | Get a bit array of what inventory we have
inventoryIndex :: [Address] -> Map Address a -> PackedInteger
inventoryIndex members inv =
  let have addr = if Map.member addr inv then 1 else 0
      shiftHave n (i, addr) = n .|. shift (have addr) i
   in foldl shiftHave 0 $ zip [0..] members

-- | Sort remote inventories by how interesting they are and remote inventory we already have
prioritiseRemoteInventory :: [Address] -> Map Address a -> [(b, PackedInteger)] -> [(b, PackedInteger)]
prioritiseRemoteInventory members inv idxs =
  let myIdx = inventoryIndex members inv
      interesting = [(p, i .&. complement myIdx) | (p, i) <- idxs]
   in sortOn (\(_,i) -> popCount i * (-1)) interesting

-- Get queries for remote inventory filtering duplicates
dedupeInventoryQueries :: [(a, PackedInteger)] -> [(a, PackedInteger)]
dedupeInventoryQueries = f 0 where
  f _ [] = []
  f seen ((peer, idx):xs) =
    let wanted = idx .&. complement seen
        rest = f (seen .|. wanted) xs
     in if wanted /= 0
           then (peer, wanted) : rest
           else []

-- Get part of the inventory according to an index
getInventorySubset :: PackedInteger -> [Address] -> Inventory a -> Inventory a
getInventorySubset idx members =
  Map.filterWithKey $
    \k _ -> let Just i = elemIndex k members
             in testBit idx i
