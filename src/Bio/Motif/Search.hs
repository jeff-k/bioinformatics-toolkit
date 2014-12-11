{-# LANGUAGE BangPatterns #-}

module Bio.Motif.Search 
    ( findTFBS
    , findTFBS'
    , findTFBSSlow
    , maxMatchSc
    , spacingConstraint
    ) where

import Bio.Seq (DNA, toBS)
import qualified Bio.Seq as Seq (length)
import Bio.Motif
import Control.Monad.Identity (runIdentity)
import Data.Conduit
import qualified Data.Conduit.List as CL
import qualified Data.HashSet as S
import Data.List (foldl', sortBy)
import Data.Ord (comparing)
import qualified Data.ByteString.Char8 as B
import qualified Data.Vector.Unboxed as U
import Statistics.Matrix hiding (map)


-- | given a user defined threshold, look for TF binding sites on a DNA 
-- sequence, using look ahead search. This function doesn't search for binding 
-- sites on the reverse strand
findTFBS :: Monad m => Bkgd -> PWM -> DNA a -> Double -> Source m Int
findTFBS bg pwm dna thres = loop 0
  where
    loop !i | i >= l - n + 1 = return ()
            | otherwise = do let (d, _) = lookAheadSearch bg pwm sigma dna i thres
                             if d == n - 1
                                then yield i >> loop (i+1)
                                else loop (i+1)
    sigma = optimalScoresSuffix bg pwm
    l = Seq.length dna
    n = size pwm
{-# INLINE findTFBS #-}

-- TODO: evaluation in parallel
findTFBS' :: Bkgd -> PWM -> DNA a -> Double -> [Int]
findTFBS' bg pwm dna th = runIdentity $ findTFBS bg pwm dna th $$ CL.consume
{-# INLINE findTFBS' #-}

-- | use naive search
findTFBSSlow :: Monad m => Bkgd -> PWM -> DNA a -> Double -> Source m Int
findTFBSSlow bg pwm dna thres = scores' bg pwm dna $= 
                                       loop 0
  where
    loop i = do v <- await
                case v of
                    Just v' ->  if v' >= thres then yield i >> loop (i+1)
                                               else loop (i+1)
                    _ -> return ()
{-# INLINE findTFBSSlow #-}

-- | the largest possible match scores starting from every position of a DNA sequence
maxMatchSc :: Bkgd -> PWM -> DNA a -> Double
maxMatchSc bg pwm dna = loop (-1/0) 0
  where
    loop !max' !i | i >= l - n + 1 = max'
                  | otherwise = if d == n - 1 then loop sc (i+1)
                                              else loop max' (i+1)
      where
        (d, sc) = lookAheadSearch bg pwm sigma dna i max'
    sigma = optimalScoresSuffix bg pwm
    l = Seq.length dna
    n = size pwm
{-# INLINE maxMatchSc #-}

optimalScoresSuffix :: Bkgd -> PWM -> U.Vector Double
optimalScoresSuffix (BG (a, c, g, t)) (PWM _ pwm) = 
    U.fromList . tail . map (last sigma -) $ sigma
  where
    sigma = scanl f 0 $ toRows pwm
    f !acc xs = let (i, s) = U.maximumBy (comparing snd) . 
                                U.zip (U.fromList ([0..3] :: [Int])) $ xs
                in acc + case i of
                    0 -> log $ s / a
                    1 -> log $ s / c
                    2 -> log $ s / g
                    3 -> log $ s / t
                    _ -> undefined
{-# INLINE optimalScoresSuffix #-}

lookAheadSearch :: Bkgd              -- ^ background nucleotide distribution
                -> PWM               -- ^ pwm
                -> U.Vector Double   -- ^ best possible match score of suffixes
                -> DNA a             -- ^ DNA sequence
                -> Int               -- ^ starting location on the DNA
                -> Double            -- ^ threshold
                -> (Int, Double)     -- ^ (d, sc_d), the largest d such that sc_d > th_d
lookAheadSearch (BG (a, c, g, t)) pwm sigma dna start thres = loop (0, -1) 0
  where
    loop (!acc, !th_d) !d 
      | acc < th_d = (d-2, acc)
      | otherwise = if d >= n
                       then (d-1, acc)
                       else loop (acc + sc, thres - sigma U.! d) (d+1)
      where
        sc = case toBS dna `B.index` (start + d) of
              'A' -> log $! matchA / a
              'C' -> log $! matchC / c
              'G' -> log $! matchG / g
              'T' -> log $! matchT / t
              'N' -> 0
              'V' -> log $! (matchA + matchC + matchG) / (a + c + g)
              'H' -> log $! (matchA + matchC + matchT) / (a + c + t)
              'D' -> log $! (matchA + matchG + matchT) / (a + g + t)
              'B' -> log $! (matchC + matchG + matchT) / (c + g + t)
              'M' -> log $! (matchA + matchC) / (a + c)
              'K' -> log $! (matchG + matchT) / (g + t)
              'W' -> log $! (matchA + matchT) / (a + t)
              'S' -> log $! (matchC + matchG) / (c + g)
              'Y' -> log $! (matchC + matchT) / (c + t)
              'R' -> log $! (matchA + matchG) / (a + g)
              _   -> error "Bio.Motif.Search.lookAheadSearch: invalid nucleotide"
        matchA = addSome $ unsafeIndex (_mat pwm) d 0
        matchC = addSome $ unsafeIndex (_mat pwm) d 1
        matchG = addSome $ unsafeIndex (_mat pwm) d 2
        matchT = addSome $ unsafeIndex (_mat pwm) d 3
        addSome !x | x == 0 = pseudoCount
                   | otherwise = x
        pseudoCount = 0.0001
    n = size pwm
{-# INLINE lookAheadSearch #-}

-- | search for spacing constraint between two TFs
spacingConstraint :: PWM
                  -> PWM
                  -> Bkgd
                  -> Double  -- ^ p-Value for motif finding
                  -> Int  -- ^ bin size
                  -> Int
                  -> DNA a -> ([(Bool, (Int, Int))], Int, Int, Int)
spacingConstraint pwm1 pwm2 bg p w k dna = (take 10 $ sortBy (flip (comparing (snd . snd))) $ same ++ oppose, n1, n2, n)
  where
    rs = let rs' = [-k, -k+2*w+1 .. 0]
         in rs' ++ map (*(-1)) (reverse rs')
    -- on the same orientation
    same = zip (repeat True) $ zip rs $ zipWith (+) nFF nRR
      where
        nFF = map (nOverlap forward1 forward2 w) rs
        nRR = map (nOverlap reverse1 reverse2 w) $ reverse rs
    oppose = zip (repeat False) $ zip rs $ zipWith (+) nFR nRF
      where
        nFR = map (nOverlap forward1 reverse2 w) rs
        nRF = map (nOverlap reverse1 forward2 w) $ reverse rs
    forward1 = findTFBS' bg pwm1 dna th1
    forward2 = S.fromList $ findTFBS' bg pwm2 dna th2
    reverse1 = map (+ (m1 - 1)) $ findTFBS' bg (rcPWM pwm1) dna th1
    reverse2 = S.fromList $ map (+ (m2 - 1)) $ findTFBS' bg (rcPWM pwm2) dna th2
    th1 = pValueToScore p bg pwm1
    th2 = pValueToScore p bg pwm2
    m1 = size pwm1
    m2 = size pwm2

    nOverlap :: [Int] -> S.HashSet Int -> Int -> Int -> Int
    nOverlap xs ys w' i = foldl' f 0 xs
      where
        f acc x | any (`S.member` ys) [x + i - w' .. x + i + w'] = acc + 1
                | otherwise = acc

{-
    pValue :: Int -> Int -> Int -> Int -> Double
    pValue overlap n1 n2 n = let prob = fromIntegral ((2*w+1)*n1) / fromIntegral n
                                 d = poisson $ prob * fromIntegral n2
                             in complCumulative d (fromIntegral overlap)
                                -}

    n1 = length forward1 + length reverse1
    n2 = S.size forward2 + S.size reverse2
    n = Seq.length dna
{-# INLINE spacingConstraint #-}
