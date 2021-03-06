{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Strict #-}

module Zeno.Process.Node where

import Data.Serialize
import qualified Data.Map as Map
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL

import Network.Simple.TCP
import Network.Socket (SockAddr(..), HostAddress, hostAddressToTuple, getSocketName)

import System.Posix.Signals

import UnliftIO
import UnliftIO.Concurrent

import Zeno.Prelude hiding (finally)
import Zeno.Process.GetIP
import Zeno.Process.Spawn
import Zeno.Process.Types
import Zeno.Process.Node.InboundRateLimit
import Zeno.Process.Remote
import Zeno.Signal


withNode :: NetworkConfig -> Zeno Node a -> Zeno () a
withNode (NetworkConfig host port ipProvider) act = do
  withRunInIO \rio -> do
    listen host (show port) $ \(server, serverAddr) -> do
      rio do
        node <- mkNode server
        setupSignals node
        withLocalResources do -- This is neccesary so that the server thread gets killed
                              -- before the socket file descriptor is cleaned up. We also
                              -- want to bind the socket in the calling thread in case of any
                              -- error and this is the simplest way to do it.
          spawn "socket server" \_ -> do
            fix \go -> do
              acceptForkAsync server $ wrapRunConn node
              go
          logInfo $ "Listening on %s" % (show serverAddr)
          withContext (const node) act
  where
  mkNode serverSock = do
    myIpStr <- ipProvider
    liftIO do
      SockAddrInet boundPort _ <- liftIO $ getSocketName serverSock
      let myNodeId = NodeId myIpStr $ fromIntegral boundPort
      capabilities <- newIORef mempty
      mforwarders <- newMVar mempty
      mreceivers <- newReceiverMap
      pure Node{..}

  acceptForkAsync :: MonadUnliftIO m => Socket -> ((Socket, SockAddr) -> ClassyAsync () -> m ()) -> m ()
  acceptForkAsync server act = do
    withRunInIO \rio -> do
      accept server \client -> do
        handoff <- newEmptyTMVarIO
        atomically . putTMVar handoff =<<
          classyAsync do
            finally
              do atomically (takeTMVar handoff) >>= rio . act client
              do closeSock $ fst client

  wrapRunConn node s@(sock, sockAddr) asnc = do
    logDiedSync ("IN:" ++ show sockAddr) do
      filterInboundConnections node sockAddr asnc $
        runConnection node sock

  setupSignals node = do
    -- http://hackage.haskell.org/package/network-2.6.0.2/docs/Network.html#g:10
    liftIO $ installHandler sigPIPE Ignore Nothing
    installSignalHandler sigUSR1 $ dumpNode node

dumpNode :: Node -> Zeno () ()
dumpNode Node{..} = do
  logInfo $ "My NodeId: " ++ show myNodeId
  forwarders <- readMVar mforwarders
  logInfo $ "Forwarders: " ++ show (length forwarders)
  receivers <- liftIO $ readReceiverMap mreceivers
  logInfo $ "Receivers: " ++ show (length receivers)


maxConn :: Int
maxConn = 20

filterInboundConnections :: Node -> SockAddr -> ClassyAsync () -> (HostAddress -> Zeno () ()) -> Zeno () ()
filterInboundConnections Node{..} sockAddr asnc act = do
  case sockAddr of
    SockAddrInet _ ip@16777343 -> do
      -- 127.0.0.1 is special. TODO: Nice way not have to do this, and also be able
      -- to test locally? Need to get the integrate script using a local docker network.
      -- Ah, it could map port ranges to local IPs,
      -- eg any port between 10k and 11k is .1, etc, and replace the incoming IP.
      -- Except we don't have the remote listen port here, for good reasons
      act ip

    SockAddrInet _ ip -> do
      actIO <- toIO $ act ip
      liftIO $ inboundConnectionLimit mreceivers ip maxConn actIO

    other -> throwIO $ UnsupportedForeignHost other


data NetworkError
  = NetworkMischief String
  | NetworkMurphy String
  | NetworkUnsupported String
  | UnsupportedForeignHost SockAddr
  deriving (Show)

instance Exception NetworkError

data ConnectionClosed = ConnectionClosed deriving (Show)
instance Exception ConnectionClosed


runConnection :: Node -> Socket -> HostAddress -> Zeno () ()
runConnection node@Node{..} conn ip = do
  -- handle (\ConnectionClosed -> mempty) do -- Don't spam up the log
    nodeId <- readHeader
    forever do
      len <- (decodeLazy <$> receiveLen 4) >>= either murphy pure :: Zeno () Word32
      receiveMessage (fromIntegral len) >>= handleMessage node nodeId
      threadDelay 10000 -- rate limit to a generous 100 messages/s

  where
  receiveMessage len = do
    when (len > 10000) do
      throwIO $ NetworkMischief $ [pf|%? sent oversize message: %?|] (renderIp ip) len
    receiveLen len

  receiveLen :: Int -> Zeno () LazyByteString
  receiveLen 0 = pure ""
  receiveLen len = do
    fix2 "" len \f xs rem -> do
      s <- recv conn rem >>= maybe (throwIO ConnectionClosed) pure
      let newbs = xs <> fromStrict s
          newrem = rem - BS.length s
      case compare newrem 0 of
        EQ -> pure newbs
        GT -> f newbs newrem
        LT -> murphy "More data received than expected"

  readHeader = do
    header <- receiveLen 3
    case decodeLazy header of
      Right ('\0', port) -> pure $ NodeId (renderIp ip) port
      Left s -> murphy s -- How can we fail to decode exactly 3 bytes into a (Word8, Word16)
      Right (_, _) -> do
        -- Someone is port scanning, or running incorrect version
        throwIO ConnectionClosed

handleMessage :: Node -> NodeId -> LazyByteString -> Zeno () ()
handleMessage _ _ "" = pure ()
handleMessage Node{..} nodeId bs = do
  let capid = CapabilityId $ BSL.head bs
  caps <- readIORef capabilities
  forM_ (Map.lookup capid caps)
    \recv -> do
      liftIO $ recv $ RemoteMessage nodeId $ BSL.tail bs
