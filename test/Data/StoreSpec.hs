{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.StoreSpec where

import           Control.Applicative
import           Control.Exception (evaluate)
import           Control.Monad (unless)
import qualified Data.Array.Unboxed as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as SBS
import           Data.Complex (Complex(..))
import           Data.Containers (mapFromList, setFromList)
import           Data.HashMap.Strict (HashMap)
import           Data.HashSet (HashSet)
import           Data.Hashable (Hashable)
import           Data.Int
import           Data.IntMap (IntMap)
import           Data.IntSet (IntSet)
import qualified Data.List.NonEmpty as NE
import           Data.Map (Map)
import           Data.Monoid
import           Data.Primitive.Types (Addr)
import           Data.Proxy (Proxy(..))
import           Data.Ratio (numerator, denominator)
import           Data.Sequence (Seq)
import           Data.Sequences (fromList)
import           Data.Set (Set)
import           Data.Store
import           Data.Store.Internal
import           Data.Store.TH
import           Data.Store.TH.Internal
import           Data.Store.TypeHash
import           Data.StoreSpec.TH
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Time as Time
import           Data.Typeable (Typeable)
import qualified Data.Vector as V
import qualified Data.Vector.Primitive as PV
import qualified Data.Vector.Storable as SV
import qualified Data.Vector.Unboxed as UV
import           Data.Void (Void)
import           Data.Word
import           Foreign.C.Types
import           Foreign.Ptr
import           Foreign.Storable (Storable, sizeOf)
import           GHC.Fingerprint.Type (Fingerprint(..))
import           GHC.Generics
import           GHC.Real (Ratio(..))
import           Language.Haskell.TH
import           Language.Haskell.TH.ReifyMany
import           Language.Haskell.TH.Syntax
import           Prelude
import           System.Posix.Types
import           Test.Hspec hiding (runIO)
import           Test.SmallCheck.Series

------------------------------------------------------------------------
-- Instances for base types

-- TODO: should be possible to do something clever where it only defines
-- instances that don't already exist.  For now, just doing it manually.

addMinAndMaxBounds :: forall a. (Bounded a, Eq a) => [a] -> [a]
addMinAndMaxBounds xs =
    (if (minBound :: a) `notElem` xs then [minBound] else []) ++
    (if (maxBound :: a) `notElem` xs && (maxBound :: a) /= minBound then maxBound : xs else xs)

$(mkManyHasTypeHash [ [t| Int32 |] ])

-- Serial instances for (Num a, Bounded a) types. Only really
-- appropriate for the use here.

$(do let ns = [ ''CWchar, ''CUShort, ''CULong, ''CULLong, ''CIntMax
              , ''CUIntMax, ''CPtrdiff, ''CSChar, ''CShort, ''CUInt, ''CLLong
              , ''CLong, ''CInt, ''CChar, ''CSsize, ''CPid
              , ''COff, ''CMode, ''CIno, ''CDev
              , ''Word8, ''Word16, ''Word32, ''Word64, ''Word
              , ''Int8, ''Int16, ''Int32, ''Int64
              ] ++
#ifdef mingw32_HOST_OS
              []
#else
              [ ''CUid, ''CTcflag, ''CRLim, ''CNlink, ''CGid ]
#endif
         f n = [d| instance Monad m => Serial m $(conT n) where
                      series = generate (\_ -> addMinAndMaxBounds [0, 1]) |]
     concat <$> mapM f ns)


-- Serial instances for (Num a) types. Only really appropriate for the
-- use here.

$(do let ns = [ ''CUSeconds, ''CClock, ''CTime, ''CUChar, ''CSize, ''CSigAtomic
              ,  ''CSUSeconds, ''CFloat, ''CDouble
              ] ++
#ifdef mingw32_HOST_OS
              []
#else
              [ ''CSpeed, ''CCc ]
#endif
         f n = [d| instance Monad m => Serial m $(conT n) where
                      series = generate (\_ -> [0, 1]) |]
     concat <$> mapM f ns)

-- Serial instances for Primitive vectors

$(do tys <- getAllInstanceTypes1 ''PV.Prim
     let f ty = [d| instance (Serial m $(return ty), Monad m) => Serial m (PV.Vector $(return ty)) where
                      series = fmap PV.fromList series |]
     concat <$> mapM f tys)

-- Instance needed for generic TH instances

-- Needs to be done manually because in GHC 7.8's TH, NameFlavour uses
-- unboxed values and cannot use generic deriving. So we skip having an
-- instance for it.
instance Monad m => Serial m Name where series = fmap mkName series

-- Serial instances for (Generic a) types.

-- FIXME: generating for TH instances is probably just adding
-- unnecessary compiletime + runtime overhead.
$(do thNames <- reifyManyWithoutInstances
         ''Serial
         [''Info, ''Loc, ''ModName, ''PkgName, ''NameSpace, ''OccName]
         (`notElem` [''NameFlavour])
     let ns = [ ''Any, ''All ] ++ thNames
         f n = [d| instance Monad m => Serial m $(conT n) |]
     concat <$> mapM f ns)

$(do let ns = [ ''Dual, ''Sum, ''Product, ''First, ''Last ]
         f n = [d| instance (Monad m, Serial m a) => Serial m ($(conT n) a) |]
     concat <$> mapM f ns)

instance Monad m => Serial m Fingerprint where
    series = generate (\_ -> [Fingerprint 0 0, Fingerprint maxBound maxBound])

instance Monad m => Serial m BS.ByteString where
    series = fmap BS.pack series

instance Monad m => Serial m LBS.ByteString where
    series = fmap LBS.pack series

instance Monad m => Serial m SBS.ShortByteString where
    series = fmap SBS.pack series

instance (Monad m, Serial m a, Storable a) => Serial m (SV.Vector a) where
    series = fmap SV.fromList series

instance (Monad m, Serial m a) => Serial m (V.Vector a) where
    series = fmap V.fromList series

instance (Monad m, Serial m k, Serial m a, Ord k) => Serial m (Map k a) where
    series = fmap mapFromList series

instance (Monad m, Serial m a, Ord a) => Serial m (Set a) where
    series = fmap setFromList series

instance (Monad m, Serial m a) => Serial m (IntMap a) where
    series = fmap mapFromList series

instance Monad m => Serial m IntSet where
    series = fmap setFromList series

instance Monad m => Serial m Text where
    series = fmap fromList series

instance (Monad m, Serial m a) => Serial m (Seq a) where
    series = fmap fromList series

instance (Monad m, Serial m a) => Serial m (Complex a) where
    series = uncurry (:+) <$> (series >< series)

instance (Monad m, Serial m a, UV.Unbox a) => Serial m (UV.Vector a) where
    series = fmap fromList series

instance (Monad m, Serial m k, Serial m a, Hashable k, Eq k) => Serial m (HashMap k a) where
    series = fmap mapFromList series

instance (Monad m, Serial m a, Hashable a, Eq a) => Serial m (HashSet a) where
    series = fmap setFromList series

instance (Monad m, A.Ix i, Serial m i, Serial m e) => Serial m (A.Array i e) where
    series = seriesArray

instance (Monad m, A.IArray A.UArray e, A.Ix i, Serial m i, Serial m e) => Serial m (A.UArray i e) where
    series = seriesArray

seriesArray :: (Monad m, A.Ix i, A.IArray a e, Serial m i, Serial m e) => Series m (a i e)
seriesArray = cons2 $ \bounds (NonEmpty xs) ->
    A.listArray bounds (take (A.rangeSize bounds) (cycle xs))

instance Monad m => Serial m Time.Day where
    series = Time.ModifiedJulianDay <$> series

instance Monad m => Serial m Time.DiffTime where
    series = Time.picosecondsToDiffTime <$> series

instance Monad m => Serial m Time.UTCTime where
    series = uncurry Time.UTCTime <$> (series >< series)

instance (Monad m, Serial m a) => Serial m (NE.NonEmpty a)

instance (Monad m, Serial m a) => Serial m (Tagged a)

-- Should probably get added to smallcheck :)
instance Monad m => Serial m Void where
    series = generate (\_ -> [])

#if !MIN_VERSION_template_haskell(2,11,0)
deriving instance Show NameFlavour
deriving instance Show NameSpace
#endif

-- We define our own Serial instance for 'Ratio' because of <https://github.com/feuerbach/smallcheck/pull/34>

newtype SerialRatio a = SerialRatio (Ratio a)
  deriving (Store, Eq, Show)

instance (Integral i, Serial m i) => Serial m (SerialRatio i) where
   series = pairToRatio <$> series
     where
      pairToRatio (n, Positive d) = SerialRatio (n :% d)

------------------------------------------------------------------------
-- Test datatypes for generics support

data Test
    = TestA Int64 Word32
    | TestB Bool
    | TestC
    | TestD BS.ByteString
    deriving (Eq, Show, Generic)
-- $(return . (:[]) =<< deriveStore [] (ConT ''Test) . dtCons =<< reifyDataType ''Test)
instance Store Test
instance Monad m => Serial m Test

data X = X
    deriving (Eq, Show, Generic)
instance Monad m => Serial m X
instance Store X


-- Datatypes with faulty instances
newtype BadIdea = BadIdea Int64
instance Store BadIdea where
    poke (BadIdea x) = poke x
    peek = BadIdea <$> peek
    size = ConstSize 1 -- too small

newtype BadIdea2 = BadIdea2 Int64
instance Store BadIdea2 where
    poke (BadIdea2 x) = poke x
    peek = BadIdea2 <$> peek
    size = ConstSize 12 -- too large

spec :: Spec
spec = do
    describe "Store on all monomorphic instances"
        $(do insts <- getAllInstanceTypes1 ''Store
             omitTys <- sequence
                 [ [t| PV.Vector Addr |]
                 , [t| CUIntPtr |]
                 , [t| CIntPtr |]
                 , [t| IntPtr |]
                 , [t| WordPtr |]
                 , [t| TypeHash |]
                 , [t| Fd |]
                 , [t| NameFlavour |]
                 ]
             let f ty = isMonoType ty && ty `notElem` omitTys
             smallcheckManyStore verbose 2 . map return . filter f $ insts)
    it "Store on non-numeric Float/Double values" $ do
        let testNonNumeric :: forall a m. (RealFloat a, Eq a, Show a, Typeable a, Store a, Monad m) => Proxy a -> m ()
            testNonNumeric _proxy = do
                assertRoundtrip verbose ((1/0) :: a)
                assertRoundtrip verbose ((-1/0) :: a)
                -- -0 == 0, so we check if the infinity sign is the same
                case decode (encode ((-0) :: a)) of
                    Right (x :: a) -> unless (-1/0 == 1/x) (fail "Could not roundtrip negative 0")
                    _ -> fail "Could not roundtrip negative 0"
                assertRoundtrip verbose ((-0) :: a)
                -- 0/0 /= 0/0, so we check for NaN explicitly
                case decode (encode ((0/0) :: a)) of
                    Right (x :: a) -> unless (isNaN x) (fail "Could not roundtrip NaN")
                    _ -> fail "Could not roundtrip NaN"
        testNonNumeric (Proxy :: Proxy Double)
        testNonNumeric (Proxy :: Proxy Float)
        testNonNumeric (Proxy :: Proxy CDouble)
        testNonNumeric (Proxy :: Proxy CFloat)
        (return () :: IO ())
    describe "Store on all custom generic instances"
        $(smallcheckManyStore verbose 2
            [ [t| Test |]
            , [t| X |]
            ])
    describe "Manually listed polymorphic store instances"
        $(smallcheckManyStore verbose 4
            [ [t| SV.Vector Int8 |]
            , [t| V.Vector  Int8 |]
            , [t| SerialRatio     Int8 |]
            , [t| Complex   Int8 |]
            , [t| Dual      Int8 |]
            , [t| Sum       Int8 |]
            , [t| Product   Int8 |]
            , [t| First     Int8 |]
            , [t| Last      Int8 |]
            , [t| Maybe     Int8 |]
            , [t| Either    Int8 Int8 |]
            , [t| SV.Vector Int64 |]
            , [t| V.Vector  Int64 |]
            , [t| SerialRatio     Int64 |]
            , [t| Complex   Int64 |]
            , [t| Dual      Int64 |]
            , [t| Sum       Int64 |]
            , [t| Product   Int64 |]
            , [t| First     Int64 |]
            , [t| Last      Int64 |]
            , [t| Maybe     Int64 |]
            , [t| Either    Int64 Int64 |]
            , [t| (Int8, Int16) |]
            , [t| (Int8, Int16, Bool) |]
            , [t| (Bool, (), (), ()) |]
            , [t| (Bool, (), Int8, ()) |]
            -- Container-ey types
            , [t| [Int8] |]
            , [t| [Int64] |]
            , [t| Seq Int8 |]
            , [t| Seq Int64 |]
            , [t| Set Int8 |]
            , [t| Set Int64 |]
            , [t| IntMap Int8 |]
            , [t| IntMap Int64 |]
            , [t| Map Int8 Int8 |]
            , [t| Map Int64 Int64 |]
            , [t| HashMap Int8 Int8 |]
            , [t| HashMap Int64 Int64 |]
            , [t| HashSet Int8 |]
            , [t| HashSet Int64 |]
            , [t| NE.NonEmpty Int8 |]
            , [t| NE.NonEmpty Int64 |]
            , [t| Tagged Int32 |]
            , [t| A.Array (Int, Integer) Integer |]
            , [t| A.UArray Char Bool |]
            ])
    it "Slices roundtrip" $ do
        assertRoundtrip False $ T.drop 3 $ T.take 3 "Hello world!"
        assertRoundtrip False $ BS.drop 3 $ BS.take 3 "Hello world!"
        assertRoundtrip False $ SV.drop 3 $ SV.take 3 (SV.fromList [1..10] :: SV.Vector Int32)
        assertRoundtrip False $ UV.drop 3 $ UV.take 3 (UV.fromList [1..10] :: UV.Vector Word8)
        (return () :: IO ())
    it "StaticSize roundtrips" $ do
        let x :: StaticSize 17 BS.ByteString
            x = toStaticSizeEx (BS.replicate 17 255)
        unless (checkRoundtrip False x) $
            (fail "Failed to roundtrip StaticSize ByteString" :: IO ())
    it "Size of generic instance for single fieldless constructor is 0" $ do
        case size :: Size X of
            ConstSize 0 -> (return () :: IO ())
            _ -> fail "Empty datatype takes up space"
    it "Printing out polymorphic store instances" $ do
        putStrLn ""
        putStrLn "Not really a test - printing out known polymorphic store instances (which should all be tested above)"
        putStrLn ""
        mapM_ putStrLn
              $(do insts <- getAllInstanceTypes1 ''Store
                   lift $ map pprint $ filter (not . isMonoType) insts)
    it "Faulty implementations of size lead to PokeExceptions" $ do
        evaluate (encode (BadIdea 0)) `shouldThrow` isPokeException
        evaluate (encode (BadIdea2 0)) `shouldThrow` isPokeException
    it "Avoids reading data with a negative size" $ do
        let bs = encode (SV.fromList [1..10::Int])
            bs' = BS.concat [encode (-1 :: Int)
                            , BS.drop (sizeOf (10 :: Int)) bs
                            ]
        evaluate (decodeEx bs' :: SV.Vector Int) `shouldThrow` isNegativeBytesException
    it "Avoids overflow in bounds checks" $ do
        let bs = encode ("some random bytestring" :: BS.ByteString)
            bs' = BS.concat [encode (maxBound :: Int)
                            , BS.drop (sizeOf (10 :: Int)) bs
                            ]
        evaluate (decodeEx bs' :: BS.ByteString) `shouldThrow` isTooManyBytesException
    it "Handles unaligned access" $ do
        assertRoundtrip verbose (250 :: Word8, 40918 :: Word16, 120471416 :: Word32)
        assertRoundtrip verbose (250 :: Word8, 10.1 :: Float, 8697.65 :: Double)
        (return () :: IO ())
    it "Expects the right marker when deserializing ordered maps (#97)" $ do
        let m = mapFromList [(1, ()), (2, ()), (3, ())] :: HashMap Int ()
            bs = encode m
        (decodeEx bs :: HashMap Int ()) `shouldBe` m
        evaluate (decodeEx bs :: Map Int ()) `shouldThrow` isUnexpectedMarkerException
        evaluate (decodeEx bs :: IntMap ()) `shouldThrow` isUnexpectedMarkerException

isPokeException :: Test.Hspec.Selector PokeException
isPokeException = const True

isNegativeBytesException :: Test.Hspec.Selector PeekException
isNegativeBytesException (PeekException _ t) = "Attempted to read negative number of bytes" `T.isPrefixOf` t

isTooManyBytesException :: Test.Hspec.Selector PeekException
isTooManyBytesException (PeekException _ t) = "Attempted to read too many bytes" `T.isPrefixOf` t

isUnexpectedMarkerException :: Test.Hspec.Selector PeekException
isUnexpectedMarkerException (PeekException _ t) =
    "Expected marker for ascending Map / IntMap: " `T.isPrefixOf` t
