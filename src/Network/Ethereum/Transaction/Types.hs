{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.Ethereum.Transaction.Types where

import           Crypto.Secp256k1.Recoverable
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as Short
import           Data.RLP as RLP
import           Data.Serialize

import           Network.Ethereum.Crypto
import           Network.Ethereum.Data.Utils
import           Zeno.Data.Aeson
import           Zeno.Data.Hex
import           Zeno.Prelude


type EthTxHash = PrefixedHex 32

data Transaction = Tx
  { _nonce    :: Integer
  , _value    :: Integer
  , _to       :: Maybe Address
  , _sig      :: Maybe RecSig
  , _gasPrice :: Integer
  , _gas      :: Integer
  , _data     :: ByteString
  , _chainId  :: ChainId
  } deriving (Eq, Show, Generic)

instance Serialize Transaction where
  put Tx{..} = do
    putPacked _nonce >> putPacked _value >> put _to >> put _sig >> putPacked _gasPrice
    putPacked _gas >> put _data >> put _chainId
  get = do
    Tx <$> getPacked <*> getPacked <*> get <*> get <*> getPacked <*> getPacked <*> get <*> get

instance RLPEncodable Transaction where
  rlpEncode tx = RLP.Array (c <> e) where

    RLP.Array c = rlpEncode

        ( _nonce tx
        , _gasPrice tx
        , _gas tx
        , maybe "" toS $ _to tx :: ByteString
        , _value tx
        , _data tx
        )
    
    RLP.Array e = rlpEncode $
        case toRSV <$> _sig tx of
          Nothing -> (unChainId $ _chainId tx, "", "")
          Just (r, s, v) -> (encodeSpecialV (_chainId tx) v, fromFixed r, fromFixed s)

  rlpDecode (RLP.Array a) | length a == 9 = do

    (_nonce, _gasPrice, _gas, to, _value, _data, sv, r, s) <- rlpDecode $ RLP.Array a

    _to <- case Short.length to of
             0  -> pure $ Nothing
             20 -> pure $ Just (Address $ unsafeToFixed to)
             _  -> Left "Invalid address"

    let pad32 "" = ""
        pad32 bs = BS.replicate (32 - BS.length bs) 0 <> bs
        (c, v) = decodeSpecialV sv
        _sig = if r == "" || s == "" then Nothing else Just (fromRSV (toFixed r) (toFixed s) v)
        _chainId = if isJust _sig then c else ChainId sv

    pure $ Tx { .. }

  rlpDecode o = error $ "Invalid RLP Transaction: " ++ show o


newtype ChainId = ChainId Word8
  deriving (Show, Num, Enum, Eq, Generic, ToJSON, FromJSON, RLPEncodable, Serialize)

unChainId :: ChainId -> Word8
unChainId (ChainId i) = i



encodeSpecialV :: ChainId -> Word8 -> Word8
encodeSpecialV (ChainId c) v = v + c * 2 + 35

decodeSpecialV :: Word8 -> (ChainId, Word8)
decodeSpecialV 27 = (1, 0)
decodeSpecialV 28 = (1, 1)
decodeSpecialV sv = let c = quot (sv - 35) 2 in (ChainId c, sv - 35 - c * 2)


instance ToJSON Transaction where
  toJSON = toJSON . Hex . rlpSerialize

instance FromJSON Transaction where
  parseJSON val = do
    Hex bs <- parseJSON val
    either fail pure $ rlpDeserialize bs
