
module DumpMessages where

import Zeno.Consensus.P2P
import Network.Transport
import Data.Binary
import Data.ByteString.Lazy (toStrict)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy.Char8 as BS8
import Data.Char
import Text.Printf
import qualified Data.Set as Set

import Zeno.Prelude
import Zeno.Process


dumpBin :: Binary a => a -> String
dumpBin = concatMap toPrint . BS8.unpack . encode
  where
  toPrint c
    | (isNumber c || isPunctuation c || c == ' ' || isAsciiUpper c || isAsciiLower c) = c:[]
    | otherwise = '\\' : show (ord c)

dump :: (Binary a, Show a) => a -> IO ()
dump a = do
  print a
  putStrLn $ dumpBin a
  putStrLn ""


dumpMessages :: IO ()
dumpMessages = do

  let pid = peerControllerPid
  let nid i = NodeId $ EndPointAddress $ toS $ "127.0.0.1:4044" ++ show i ++ ":0:8"
  let hello = (peerControllerPid, GetPeers)
  let peers = (peerControllerPid, Set.fromList [nid 2, nid 3, nid 4])

  print "Process ID of Peer Controller"
  dump $ peerControllerPid

  print "1: GetPeers - node sends message to p2p service on another node"
  dump hello

  print "2: node replied with peer list"
  dump peers
