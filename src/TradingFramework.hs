{-# LANGUAGE RecursiveDo #-}

module TradingFramework where

import System.IO                (hPutStr, hPutStrLn, stderr)
import Control.Exception.Base   (finally)
import Data.Maybe

import Pipes.Concurrent

import Reactive.Banana
import Reactive.Banana.Frameworks

import Market.Types
import Market.Util
import Razao.Util
import Combinator

-- changing the names to better match the semantics
type HandlerSet = AddHandler
newHandlerSet   = newAddHandler
fromHandlerSet  = fromAddHandler
activate        = actuate

--------------------------------------------------------------------------------
--                      FRAMEWORK HELPER FUNCTIONS
--------------------------------------------------------------------------------
showReasoning :: StrategyAdvice p v -> IO ()
showReasoning (ToDo _ reasons) = putStrLn reasons

logAndExecute :: Output (Action p v) -> StrategyAdvice p v -> IO ()
logAndExecute output (ToDo actions reasons) = do
  hPutStr stderr reasons -- reasons must explicitly include '\n' if desired.
  sequence_ $ (atomically . send output) <$> actions

runExecutor :: Handler (Action p v) -> Input (Action p v) -> IO ()
runExecutor executor inputQueue =
  whileJustThenFinally_
    (atomically $ recv inputQueue)
    (hPutStrLn stderr "\nExecutor exiting!")
    executor

-- `finally` forces us to stick to the IO monad here when it really should be more general
whileJustThenFinally_ :: IO (Maybe a) -> IO c -> (a -> IO b) -> IO ()
whileJustThenFinally_ p endAction loopAction = finally go endAction
  where go = do
          x <- p
          case x of
            Nothing -> return ()
            Just x  -> do
              loopAction x
              go

splitEvents
    :: Event (TradingE p v q c)
    -> ( Event (OrderPlacement    p v)
       , Event (OrderCancellation    )
       , Event (OrderFill         p v)
       , Event (QuoteBook         p v q c)
       )
splitEvents es =
       ( toPlace  <$> filterE isPlace  es
       , toCancel <$> filterE isCancel es
       , toFill   <$> filterE isFill   es
       , toBook   <$> filterE isBook   es
       )
  where
    isPlace TP{}  = True
    isPlace _     = False

    isCancel TC{} = True
    isCancel _    = False

    isFill TF{}   = True
    isFill _      = False

    isBook TB{}   = True
    isBook _      = False

--------------------------------------------------------------------------------
--                     SIMPLE TRADING STRATEGIES
--------------------------------------------------------------------------------
showBook :: (Coin p, Coin v, Show counter)
         => place
         -> cancel
         -> fill
         -> MomentIO (Event (QuoteBook p v qtail counter))
         -> (Event (StrategyAdvice p v) -> MomentIO ())
         -> MomentIO ()
showBook _ _ _ newBooks runOnOutputEvents = mdo
    eNewBook <- newBooks
    runOnOutputEvents (toAdvice <$> eNewBook)
  where
    toAdvice = \book -> ToDo [] (backtrackCursor $ showTopN 3 book)

--------------------------------------------------------------------------------
showAllBooks
    :: ( Coin p1, Coin v1, Show c1, Num c1
       , Coin p2, Coin v2, Show c2, Num c2
       , Coin p3, Coin v3, Show c3, Num c3)
    =>  Event (TradingE p1 v1 q1 c1)
    ->  Event (TradingE p2 v2 q2 c2)
    ->  Event (TradingE p3 v3 q3 c3)
    -> (Event (StrategyAdvice p1 v1) -> MomentIO ())
    -> (Event (StrategyAdvice p2 v2) -> MomentIO ())
    -> (Event (StrategyAdvice p3 v3) -> MomentIO ())
    -> MomentIO ()
showAllBooks e1s e2s e3s runOnE1 runOnE2 runOnE3 = do
    let (_, _, _, eb1s) = splitEvents e1s
        (_, _, _, eb2s) = splitEvents e2s
        (_, _, _, eb3s) = splitEvents e3s

    b1 <- accumB (QuoteBook {bids = [], asks = [], counter = 0}) (const <$> eb1s)
    b2 <- accumB (QuoteBook {bids = [], asks = [], counter = 0}) (const <$> eb2s)
    b3 <- accumB (QuoteBook {bids = [], asks = [], counter = 0}) (const <$> eb3s)

    runOnE3 ((\x y z -> toAdvice z x y) <$> b2 <*> b3 <@> eb1s)  -- USD-BTC is fastest market

  where
    toAdvice bk1 bk2 bk3 =
      ToDo [] (backtrackCursor $ (take 50 $ repeat '#') ++ "\n"
                              ++ showTopN 3 bk1
                              ++ (take 50 $ repeat '#') ++ "\n"
                              ++ showTopN 3 bk2
                              ++ (take 50 $ repeat '#') ++ "\n"
                              ++ showTopN 3 bk3
                              ++ (take 50 $ repeat '#') ++ "\n"
                              ++ "Asks: " ++ show a1 ++ " - " ++ show a2 ++ " - " ++ show a3 ++ "\n"
                              ++ "Bids: " ++ show b1 ++ " - " ++ show b2 ++ " - " ++ show b3 ++ "\n"
                              ++ (take 50 $ repeat '#') ++ "\n"
                              ++ "as':  " ++ show da1 ++ " - " ++ show da2 ++ " - " ++ show da3 ++ " (lower is better)\n"
                              ++ "bs':  " ++ show db1 ++ " - " ++ show db2 ++ " - " ++ show db3 ++ " (higher is better)\n"
                              )
      where
        a1 = best 99999 (asks bk1)
        a2 = best 99999 (asks bk2)
        a3 = best 99999 (asks bk3)
        b1 = best     0 (bids bk1)
        b2 = best     0 (bids bk2)
        b3 = best     0 (bids bk3)
        da1 = Price $ round2dp $ ((realToFrac a2 * 1.0025 * 1.0025 / realToFrac b3)   :: USD )
        db1 = Price $ round2dp $ ((realToFrac b2 / realToFrac a3 / (1.0025 * 1.0025)) :: USD )
        da2 = Price $ round2dp $ ((realToFrac a3 * 1.0025 * 1.0025 * realToFrac a1)   :: USD )
        db2 = Price $ round2dp $ ((realToFrac b3 * realToFrac b1 / (1.0025 * 1.0025)) :: USD )
        da3 = Price $            ((realToFrac a2 * 1.0025 * 1.0025 / realToFrac b1)   :: BTC )
        db3 = Price $            ((realToFrac b2 / realToFrac a1 / (1.0025 * 1.0025)) :: BTC )


    best :: (Coin p, Coin v) => Price p -> [Quote p v q] -> Price p
    best p qs = fromMaybe p (getBestPrice' qs)

--------------------------------------------------------------------------------
cancelAllLimitOrders
    :: (Coin p, Coin v)
    => Event (TradingE p v q c)
    -> (Event (StrategyAdvice p v) -> MomentIO ())
    -> MomentIO ()
cancelAllLimitOrders es runOnOutputEvents =
  let (ep, _, _, _) = splitEvents es
   in runOnOutputEvents (cancelLimitOrders ep)

--------------------------------------------------------------------------------
-- | Places an order and then cancels it. Detects cancellation.
dumbStrategy
    :: (Coin p, Coin v)
    => Event (TradingE p v q c)
    -> (Event (StrategyAdvice p v) -> MomentIO ())
    -> MomentIO ()
dumbStrategy es outputEvents = mdo
  let eAny           = const () <$> es
      (eP, eC, _, _) = splitEvents  es
      forceCancel    = cancelLimitOrders eP
      noticeCancel   = const (ToDo [] "Detected cancellation!\n") <$> eC

  placeOrder <- once (ToDo [NewLimitOrder Ask 99555 0.01] "Placing an ask!\n") eAny

  -- This is a next step, Monoid instance!
  outputEvents $ unionWith const (unionWith (error "Conflict!") placeOrder forceCancel) noticeCancel

--------------------------------------------------------------------------------
--                            COMBINATORS
--------------------------------------------------------------------------------

onAny :: (Coin p, Coin v)
       => Event (OrderPlacement    p v)
       -> Event (OrderCancellation    )
       -> Event (OrderFill         p v)
       -> Event (QuoteBook         p v q c)
       -> Event ()
onAny eNewBook eNewPlacement eNewCancels eNewFills =
  let eB = const () <$> eNewBook
      eP = const () <$> eNewPlacement
      eC = const () <$> eNewCancels
      eF = const () <$> eNewFills
      eAny = unionWith const
                (unionWith const eF eC)
                (unionWith const eP eB)
   in eAny

-- | Issue cancellation for any limit order seen.
cancelLimitOrders :: (Coin p, Coin v) => Event (OrderPlacement p v) -> Event (StrategyAdvice p v)
cancelLimitOrders ePlaced =
  let getOrd (Placement o) = o
      toAdvice a = ToDo [a] ("Canceling placed limit order: " ++ show a ++ "\n")
   in (toAdvice . CancelLimitOrder . getOrderID) <$> filterE isLimitOrder (getOrd <$> ePlaced)
