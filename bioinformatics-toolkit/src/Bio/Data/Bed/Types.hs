{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Bio.Data.Bed.Types
    ( BEDLike(..)
    , BEDConvert(..)
    , BED
    , BED3
    , NarrowPeak
    , BEDExt(..)
    , BEDTree
    ) where

import           Control.Lens
import qualified Data.ByteString.Char8             as B
import           Data.ByteString.Lex.Integral      (packDecimal)
import           Data.Default.Class                (Default (..))
import           Data.Double.Conversion.ByteString (toShortest)
import qualified Data.HashMap.Strict               as M
import qualified Data.IntervalMap.Strict           as IM
import           Data.Maybe                        (fromJust, fromMaybe)
import           Data.Monoid                       ((<>))

import           Bio.Utils.Misc                    (readDouble, readInt)

-- | A class representing BED-like data, e.g., BED3, BED6 and BED12. BED format
-- uses 0-based index (see documentation).
class BEDLike b where
    -- | Field lens
    chrom :: Lens' b B.ByteString
    chromStart :: Lens' b Int
    chromEnd :: Lens' b Int
    name :: Lens' b (Maybe B.ByteString)
    score :: Lens' b (Maybe Double)
    strand :: Lens' b (Maybe Bool)

    -- | Return the size of a bed region.
    size :: b -> Int
    size bed = bed^.chromEnd - bed^.chromStart
    {-# INLINE size #-}

    {-# MINIMAL chrom, chromStart, chromEnd, name, score, strand #-}

class BEDLike b => BEDConvert b where
    -- | Construct bed record from chromsomoe, start location and end location
    asBed :: B.ByteString -> Int -> Int -> b

    -- | Convert bytestring to bed format
    fromLine :: B.ByteString -> b

    -- | Convert bed to bytestring
    toLine :: b -> B.ByteString

    convert :: BEDLike b' => b' -> b
    convert bed = asBed (bed^.chrom) (bed^.chromStart) (bed^.chromEnd)
    {-# INLINE convert #-}

    {-# MINIMAL asBed, fromLine, toLine #-}

-- * BED6 format

-- | BED6 format, as described in http://genome.ucsc.edu/FAQ/FAQformat.html#format1.7
data BED = BED
    { _chrom      :: !B.ByteString
    , _chromStart :: {-# UNPACK #-} !Int
    , _chromEnd   :: {-# UNPACK #-} !Int
    , _name       :: !(Maybe B.ByteString)
    , _score      :: !(Maybe Double)
    , _strand     :: !(Maybe Bool)  -- ^ True: "+", False: "-"
    } deriving (Eq, Show, Read)

instance Ord BED where
    compare (BED x1 x2 x3 x4 x5 x6) (BED y1 y2 y3 y4 y5 y6) =
        compare (x1,x2,x3,x4,x5,x6) (y1,y2,y3,y4,y5,y6)

instance BEDLike BED where
    chrom = lens _chrom (\bed x -> bed { _chrom = x })
    chromStart = lens _chromStart (\bed x -> bed { _chromStart = x })
    chromEnd = lens _chromEnd (\bed x -> bed { _chromEnd = x })
    name = lens _name (\bed x -> bed { _name = x })
    score = lens _score (\bed x -> bed { _score = x })
    strand = lens _strand (\bed x -> bed { _strand = x })

instance BEDConvert BED where
    asBed chr s e = BED chr s e Nothing Nothing Nothing

    fromLine l = f $ take 6 $ B.split '\t' l
      where
        f [f1,f2,f3,f4,f5,f6] = BED f1 (readInt f2) (readInt f3) (getName f4)
            (getScore f5) (getStrand f6)
        f [f1,f2,f3,f4,f5] = BED f1 (readInt f2) (readInt f3) (getName f4)
            (getScore f5) Nothing
        f [f1,f2,f3,f4] = BED f1 (readInt f2) (readInt f3) (getName f4)
            Nothing Nothing
        f [f1,f2,f3] = asBed f1 (readInt f2) (readInt f3)
        f _ = error "Read BED fail: Not enough fields!"
        getName x | x == "." = Nothing
                  | otherwise = Just x
        getScore x | x == "." = Nothing
                   | otherwise = Just . readDouble $ x
        getStrand str | str == "-" = Just False
                      | str == "+" = Just True
                      | otherwise = Nothing
    {-# INLINE fromLine #-}

    toLine (BED f1 f2 f3 f4 f5 f6) = B.intercalate "\t"
        [ f1, (B.pack.show) f2, (B.pack.show) f3, fromMaybe "." f4, score'
        , strand' ]
      where
        strand' | f6 == Just True = "+"
                | f6 == Just False = "-"
                | otherwise = "."
        score' = case f5 of
                     Just x -> (B.pack.show) x
                     _      -> "."
    {-# INLINE toLine #-}

    convert bed = BED (bed^.chrom) (bed^.chromStart) (bed^.chromEnd) (bed^.name)
                      (bed^.score) (bed^.strand)

-- * BED3 format

data BED3 = BED3
    { _bed3_chrom       :: !B.ByteString
    , _bed3_chrom_start :: !Int
    , _bed3_chrom_end   :: !Int
    } deriving (Eq, Show, Read)

instance Ord BED3 where
    compare (BED3 x1 x2 x3) (BED3 y1 y2 y3) = compare (x1,x2,x3) (y1,y2,y3)

instance BEDLike BED3 where
    chrom = lens _bed3_chrom (\bed x -> bed { _bed3_chrom = x })
    chromStart = lens _bed3_chrom_start (\bed x -> bed { _bed3_chrom_start = x })
    chromEnd = lens _bed3_chrom_end (\bed x -> bed { _bed3_chrom_end = x })
    name = lens (const Nothing) (\bed _ -> bed)
    score = lens (const Nothing) (\bed _ -> bed)
    strand = lens (const Nothing) (\bed _ -> bed)

instance BEDConvert BED3 where
    asBed = BED3

    fromLine l = case B.split '\t' l of
                    (a:b:c:_) -> BED3 a (readInt b) $ readInt c
                    _ -> error "Read BED fail: Incorrect number of fields"
    {-# INLINE fromLine #-}

    toLine (BED3 a b c) = B.intercalate "\t"
        [a, fromJust $ packDecimal b, fromJust $ packDecimal c]
    {-# INLINE toLine #-}

-- | ENCODE narrowPeak format: https://genome.ucsc.edu/FAQ/FAQformat.html#format12
data NarrowPeak = NarrowPeak
    { _npChrom  :: !B.ByteString
    , _npStart  :: !Int
    , _npEnd    :: !Int
    , _npName   :: !(Maybe B.ByteString)
    , _npScore  :: !Double
    , _npStrand :: !(Maybe Bool)
    , _npSigal  :: !Double
    , _npPvalue :: !(Maybe Double)
    , _npQvalue :: !(Maybe Double)
    , _npPeak   :: !(Maybe Int)
    } deriving (Eq, Show, Read)

instance BEDLike NarrowPeak where
    chrom = lens _npChrom (\bed x -> bed { _npChrom = x })
    chromStart = lens _npStart (\bed x -> bed { _npStart = x })
    chromEnd = lens _npEnd (\bed x -> bed { _npEnd = x })
    name = lens _npName (\bed x -> bed { _npName = x })
    score = lens (Just . _npScore) (\bed x -> bed { _npScore = fromJust x })
    strand = lens _npStrand (\bed x -> bed { _npStrand = x })

instance BEDConvert NarrowPeak where
    asBed chr s e = NarrowPeak chr s e Nothing 0 Nothing 0 Nothing Nothing Nothing

    fromLine l = NarrowPeak a (readInt b) (readInt c)
        (if d == "." then Nothing else Just d)
        (readDouble e)
        (if f == "." then Nothing else if f == "+" then Just True else Just False)
        (readDouble g)
        (if readDouble h < 0 then Nothing else Just $ readDouble h)
        (if readDouble i < 0 then Nothing else Just $ readDouble i)
        (if readInt j < 0 then Nothing else Just $ readInt j)
      where
        (a:b:c:d:e:f:g:h:i:j:_) = B.split '\t' l
    {-# INLINE fromLine #-}

    toLine (NarrowPeak a b c d e f g h i j) = B.intercalate "\t"
        [ a, fromJust $ packDecimal b, fromJust $ packDecimal c, fromMaybe "." d
        , toShortest e
        , case f of
            Nothing   -> "."
            Just True -> "+"
            _         -> "-"
        , toShortest g, fromMaybe "-1" $ fmap toShortest h
        , fromMaybe "-1" $ fmap toShortest i
        , fromMaybe "-1" $ fmap (fromJust . packDecimal) j
        ]
    {-# INLINE toLine #-}

    convert bed = NarrowPeak (bed^.chrom) (bed^.chromStart) (bed^.chromEnd) (bed^.name)
        (fromMaybe 0 $ bed^.score) (bed^.strand) 0 Nothing Nothing Nothing

data BEDExt bed a = BEDExt
    { _ext_bed :: bed
    , _ext_data :: a
    } deriving (Eq, Show, Read)

makeLensesFor [("_ext_bed", "_bed"), ("_ext_data", "_data")] ''BEDExt

instance BEDLike bed => BEDLike (BEDExt bed a) where
    chrom = _bed . chrom
    chromStart = _bed . chromStart
    chromEnd = _bed . chromEnd
    name = _bed . name
    score = _bed . score
    strand = _bed . strand

instance (Default a, Read a, Show a, BEDConvert bed) => BEDConvert (BEDExt bed a) where
    asBed chr s e = BEDExt (asBed chr s e) def

    fromLine l = let (a, b) = B.breakEnd (=='\t') l
                 in BEDExt (fromLine $ B.init a) $ read $ B.unpack b
    {-# INLINE fromLine #-}

    toLine (BEDExt bed a) = toLine bed <> "\t" <> B.pack (show a)
    {-# INLINE toLine #-}

type BEDTree a = M.HashMap B.ByteString (IM.IntervalMap Int a)
