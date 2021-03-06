{-# LANGUAGE RankNTypes #-}

module Zeno.Process.Types where

import Control.Applicative
import Control.Monad.Reader
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Hashable (Hashable)
import qualified Data.Map as Map
import Data.Serialize
import Data.String
import Data.Typeable
import Data.Word
import GHC.Generics (Generic)
import Network.Simple.TCP
import Network.Socket (HostAddress)
import UnliftIO
import Data.FixedBytes
import Zeno.Monad
import Zeno.Process.Node.InboundRateLimit

data NodeId = NodeId
  { hostName :: !HostName
  , hostPort :: !Word16
  } deriving (Eq, Ord, Generic)

instance Show NodeId where
  show NodeId{..} = hostName ++ ":" ++ show hostPort

instance Hashable NodeId
instance Serialize NodeId

instance IsString NodeId where
  fromString s =
    let ip = takeWhile (/=':') s
        port = read $ drop (length ip + 1) s
     in NodeId ip port


data Node = Node
  { myNodeId :: NodeId
  , capabilities :: IORef (Map.Map CapabilityId (RemoteMessage BSL.ByteString -> IO ()))
  , mforwarders :: MVar (Map.Map NodeId Forwarder)
  , mreceivers :: ReceiverMap IO
  }

type Forwarder = (TQueue ForwardMessage, IORef (IO ()))

type ForwardMessage = BSL.ByteString

type Receiver i = TBQueue i

type RemoteReceiver i = Receiver (RemoteMessage i)

data RemoteMessage i = RemoteMessage
  { remoteNodeId :: NodeId
  , remoteMessage :: i
  } deriving (Eq, Functor, Show, Typeable)


newtype CapabilityId = CapabilityId Word8
  deriving (Show, Eq, Ord, Num, Serialize, Hashable)

type Process i = AsyncProcess i ()

data AsyncProcess i b = Process
  { procAsync :: Async b
  , procMbox :: TBQueue i
  }

class HasReceive r i | r -> i where
  receiveSTM :: r -> STM i
  receiveMaybeSTM :: r -> STM (Maybe i)
  receiveMaybeSTM r = Just <$> receiveSTM r <|> pure Nothing

instance HasReceive (AsyncProcess i b) i where
  receiveSTM (Process{..}) = readTBQueue procMbox
  receiveMaybeSTM (Process{..}) = tryReadTBQueue procMbox

instance HasReceive (TQueue i) i where
  receiveSTM = readTQueue
  receiveMaybeSTM = tryReadTQueue

instance HasReceive (TBQueue i) i where
  receiveSTM = readTBQueue
  receiveMaybeSTM = tryReadTBQueue

instance HasReceive (TMVar i) i where
  receiveSTM = takeTMVar
  receiveMaybeSTM = tryTakeTMVar


data NetworkConfig = NetworkConfig
  { hostPref :: HostPreference
  , port :: Word16
  , getIP :: Zeno () String
  }


class Monad m => HasNode m where
  type HandlerMonad m :: * -> *
  sendRemoteBS :: NodeId -> CapabilityId -> BSL.ByteString -> m ()
  monitorRemote :: NodeId -> m () -> m ()
  registerCapability :: CapabilityId -> (RemoteMessage BSL.ByteString -> (HandlerMonad m) ()) -> m ()
  getMyIp :: m String
