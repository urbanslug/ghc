{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

module Main where

import GHC.Exts

checkI
    :: (Int, Int)                          -- ^ expected results
    -> (Int# -> Int# -> (# Int#, Int# #))  -- ^ primop
    -> Int                                 -- ^ first argument
    -> Int                                 -- ^ second argument
    -> Maybe String                        -- ^ maybe error
checkI (expX, expY) op (I# a) (I# b) =
  case op a b of
      (# x, y #)
          | I# x == expX && I# y == expY -> Nothing
          | otherwise ->
              Just $
                  "Expected " ++ show expX ++ " and " ++ show expY
                      ++ " but got " ++ show (I# x) ++ " and " ++ show (I# y)
checkW
    :: (Word, Word)                            -- ^ expected results
    -> (Word# -> Word# -> (# Word#, Word# #))  -- ^ primop
    -> Word                                    -- ^ first argument
    -> Word                                    -- ^ second argument
    -> Maybe String                            -- ^ maybe error
checkW (expX, expY) op (W# a) (W# b) =
    case op a b of
        (# x, y #)
            | W# x == expX && W# y == expY -> Nothing
            | otherwise ->
                Just $
                    "Expected " ++ show expX ++ " and " ++ show expY
                        ++ " but got " ++ show (W# x) ++ " and " ++ show (W# y)

check :: String -> Maybe String -> IO ()
check s (Just err) = error $ "Error for " ++ s ++ ": " ++ err
check _ Nothing    = return ()

main :: IO ()
main = do
    -- First something trivial
    check "addIntC# maxBound 0" $ checkI (maxBound, 0) addIntC# maxBound 0
    check "addIntC# 0 maxBound" $ checkI (maxBound, 0) addIntC# 0 maxBound
    -- Overflows
    check "addIntC# maxBound 1" $ checkI (minBound, 1) addIntC# maxBound 1
    check "addIntC# 1 maxBound" $ checkI (minBound, 1) addIntC# 1 maxBound
    check "addIntC# maxBound 2" $ checkI (minBound + 1, 1) addIntC# maxBound 2
    check "addIntC# 2 maxBound" $ checkI (minBound + 1, 1) addIntC# 2 maxBound
    check "addIntC# minBound minBound" $
      checkI (0, 1) addIntC# minBound minBound

    -- First something trivial
    check "subIntC# minBound 0" $ checkI (minBound, 0) subIntC# minBound 0
    -- Overflows
    check "subIntC# minBound 1" $ checkI (maxBound, 1) subIntC# minBound 1
    check "subIntC# minBound 1" $ checkI (maxBound - 1, 1) subIntC# minBound 2
    check "subIntC# 0 minBound" $ checkI (minBound, 1) subIntC# 0 minBound
    check "subIntC# -1 minBound" $ checkI (maxBound, 0) subIntC# (-1) minBound
    check "subIntC# minBound -1" $
      checkI (minBound + 1, 0) subIntC# minBound (-1)

    -- First something trivial (note that the order of results is different!)
    check "plusWord2# maxBound 0" $ checkW (0, maxBound) plusWord2# maxBound 0
    check "plusWord2# 0 maxBound" $ checkW (0, maxBound) plusWord2# 0 maxBound
    -- Overflows
    check "plusWord2# maxBound 1" $
      checkW (1, minBound) plusWord2# maxBound 1
    check "plusWord2# 1 maxBound" $
      checkW (1, minBound) plusWord2# 1 maxBound
    check "plusWord2# maxBound 2" $
      checkW (1, minBound + 1) plusWord2# maxBound 2
    check "plusWord2# 2 maxBound" $
      checkW (1, minBound + 1) plusWord2# 2 maxBound
