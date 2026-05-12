//+------------------------------------------------------------------+
//|                                          EMA_Pullback_EA.mq5     |
//|                                          Copyright 2026, TamPV   |
//+------------------------------------------------------------------+
#property copyright "TamPV"
#property version   "2.00"
#property description "3 EMA Pullback + Price Action Confirmation"
#property description "Entry: Touch EMA -> Wait Pinbar/Engulfing -> Enter"
#property description "SL: Below/Above candle cluster wick + buffer"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== EMA Settings ==="
input int              InpPeriodFast     = 34;              // EMA Fast Period
input int              InpPeriodMid      = 89;              // EMA Mid Period
input int              InpPeriodSlow     = 200;             // EMA Slow Period

input group "=== Trade Settings ==="
input bool             InpUseEMA34       = true;            // Enable Entry at EMA34
input bool             InpUseEMA89       = true;            // Enable Entry at EMA89
input bool             InpUseEMA200      = true;            // Enable Entry at EMA200
input double           InpRiskPerTrade   = 50.0;            // Risk per trade ($)
input double           InpSL_Buffer      = 3.0;             // SL Buffer beyond candle wick (price $)
input int              InpMaxWaitBars    = 5;               // Max bars to wait for confirmation
input int              InpMagicNumber    = 345890;          // Magic Number
input int              InpSlippage       = 30;              // Slippage (points)

input group "=== Pattern Detection ==="
input double           InpPinbarRatio    = 2.0;             // Pinbar: wick/body minimum ratio
input double           InpMinCandleRange = 1.0;             // Min candle range to qualify (price $)

input group "=== Export Settings ==="
input string           InpExportFileName = "EMA_Pullback_History.csv"; // CSV File Name (in MQL5/Files)

//+------------------------------------------------------------------+
//| Enums & Structures                                                |
//+------------------------------------------------------------------+
enum ENUM_DIR { DIR_NONE=0, DIR_BUY=1, DIR_SELL=2 };

enum ENUM_LV_STATE
{
   LV_WAIT_TOUCH,       // Waiting for price to touch EMA
   LV_WAIT_CONFIRM,     // Touched - waiting for Pinbar/Engulfing
   LV_DONE              // Entry executed
};

struct SLevel
{
   ENUM_LV_STATE state;
   int           waitBars;      // Bars waited since touch
   double        clusterLow;    // Lowest low in candle cluster (BUY SL ref)
   double        clusterHigh;   // Highest high in candle cluster (SELL SL ref)
   ulong         ticket;        // Position ticket

   void Init()
   {
      state       = LV_WAIT_TOUCH;
      waitBars    = 0;
      clusterLow  = DBL_MAX;
      clusterHigh = 0;
      ticket      = 0;
   }
};

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
int g_hEMA34, g_hEMA89, g_hEMA200;
CTrade g_trade;

ENUM_DIR g_direction = DIR_NONE;
bool     g_setupValid = false;
SLevel   g_lv34, g_lv89, g_lv200;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Calculate lot size so that SL = exactly $InpRiskPerTrade          |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePrice)
{
   if(slDistancePrice <= 0) return 0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickSize == 0 || tickValue == 0) return minLot;

   // Value lost per 1 lot when price moves slDistancePrice
   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot == 0) return minLot;

   double lots = InpRiskPerTrade / lossPerLot;

   // Round down to lot step
   lots = MathFloor(lots / lotStep) * lotStep;

   // If lot < minimum (0.01), skip this trade to protect risk
   if(lots < minLot)
   {
      Print("WARNING: Calculated lot=", NormalizeDouble(lots,4),
            " < minLot=", minLot,
            " | SL distance=", slDistancePrice,
            " too large for $", InpRiskPerTrade, " risk. SKIPPING trade.");
      return 0;
   }

   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Normalize price                                                   |
//+------------------------------------------------------------------+
double NP(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Pattern Detection: Bullish Pinbar (Hammer)                        |
//+------------------------------------------------------------------+
bool IsBullishPinbar(int shift)
{
   double o = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double c = iClose(_Symbol, PERIOD_CURRENT, shift);
   double h = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double l = iLow(_Symbol, PERIOD_CURRENT, shift);
   if(h - l < InpMinCandleRange) return false;

   double body      = MathAbs(c - o);
   double lowerWick = MathMin(o, c) - l;
   double upperWick = h - MathMax(o, c);
   if(body == 0) body = _Point; // avoid div by zero

   return (c >= o && lowerWick >= InpPinbarRatio * body && upperWick <= body);
}

//+------------------------------------------------------------------+
//| Pattern Detection: Bearish Pinbar (Shooting Star)                 |
//+------------------------------------------------------------------+
bool IsBearishPinbar(int shift)
{
   double o = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double c = iClose(_Symbol, PERIOD_CURRENT, shift);
   double h = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double l = iLow(_Symbol, PERIOD_CURRENT, shift);
   if(h - l < InpMinCandleRange) return false;

   double body      = MathAbs(c - o);
   double lowerWick = MathMin(o, c) - l;
   double upperWick = h - MathMax(o, c);
   if(body == 0) body = _Point;

   return (c <= o && upperWick >= InpPinbarRatio * body && lowerWick <= body);
}

//+------------------------------------------------------------------+
//| Pattern Detection: Bullish Engulfing                              |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int shift)
{
   double o1 = iOpen(_Symbol, PERIOD_CURRENT, shift+1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, shift+1);
   double o2 = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double c2 = iClose(_Symbol, PERIOD_CURRENT, shift);
   if(iHigh(_Symbol, PERIOD_CURRENT, shift) - iLow(_Symbol, PERIOD_CURRENT, shift) < InpMinCandleRange)
      return false;

   return (c1 < o1 && c2 > o2 && c2 > o1 && o2 <= c1);
}

//+------------------------------------------------------------------+
//| Pattern Detection: Bearish Engulfing                              |
//+------------------------------------------------------------------+
bool IsBearishEngulfing(int shift)
{
   double o1 = iOpen(_Symbol, PERIOD_CURRENT, shift+1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, shift+1);
   double o2 = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double c2 = iClose(_Symbol, PERIOD_CURRENT, shift);
   if(iHigh(_Symbol, PERIOD_CURRENT, shift) - iLow(_Symbol, PERIOD_CURRENT, shift) < InpMinCandleRange)
      return false;

   return (c1 > o1 && c2 < o2 && o2 >= c1 && c2 <= o1);
}

//+------------------------------------------------------------------+
//| Combined confirmation check                                       |
//+------------------------------------------------------------------+
bool HasBullishConfirm(int shift) { return IsBullishPinbar(shift) || IsBullishEngulfing(shift); }
bool HasBearishConfirm(int shift) { return IsBearishPinbar(shift) || IsBearishEngulfing(shift); }

//+------------------------------------------------------------------+
//| Count EA positions                                                |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
         && PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if position exists                                          |
//+------------------------------------------------------------------+
bool PositionExists(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

//+------------------------------------------------------------------+
//| Close all EA positions                                            |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
         && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         g_trade.PositionClose(ticket);
         Print("Closed position #", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Reset all state                                                   |
//+------------------------------------------------------------------+
void ResetState()
{
   g_direction  = DIR_NONE;
   g_setupValid = false;
   g_lastBarTime = 0;
   g_lv34.Init();
   g_lv89.Init();
   g_lv200.Init();
   Print("=== State Reset - New monitoring cycle ===");
}

//+------------------------------------------------------------------+
//| Open BUY                                                          |
//+------------------------------------------------------------------+
bool OpenBuy(double sl, double tp, double lots, string comment, ulong &ticket)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   sl = NP(sl); tp = NP(tp);
   if(lots <= 0) { Print("BUY SKIP: ", comment, " lot=0"); return false; }
   if(g_trade.Buy(lots, _Symbol, ask, sl, tp, comment))
   {
      ticket = g_trade.ResultOrder();
      Print("BUY: ", comment, " #", ticket, " Lot=", lots, " @", ask, " SL=", sl, " TP=", tp);
      return true;
   }
   Print("BUY FAILED: ", comment, " Lot=", lots, " Err=", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Open SELL                                                         |
//+------------------------------------------------------------------+
bool OpenSell(double sl, double tp, double lots, string comment, ulong &ticket)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sl = NP(sl); tp = NP(tp);
   if(lots <= 0) { Print("SELL SKIP: ", comment, " lot=0"); return false; }
   if(g_trade.Sell(lots, _Symbol, bid, sl, tp, comment))
   {
      ticket = g_trade.ResultOrder();
      Print("SELL: ", comment, " #", ticket, " Lot=", lots, " @", bid, " SL=", sl, " TP=", tp);
      return true;
   }
   Print("SELL FAILED: ", comment, " Lot=", lots, " Err=", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Export trade data to CSV                                          |
//+------------------------------------------------------------------+
void ExportTradeToCSV(ulong ticket)
{
   if(ticket == 0) return;
   if(!HistorySelectByPosition(ticket)) return;

   int totalDeals = HistoryDealsTotal();
   ulong dealIn = 0, dealOut = 0;
   double profit = 0, commission = 0, swap = 0, lots = 0;
   double sl = 0, tp = 0;
   string type = "", symbol = "", comment = "";
   datetime timeIn = 0, timeOut = 0;

   for(int i = 0; i < totalDeals; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
      {
         dealIn = d;
         timeIn = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         lots = HistoryDealGetDouble(d, DEAL_VOLUME);
         symbol = HistoryDealGetString(d, DEAL_SYMBOL);
         comment = HistoryDealGetString(d, DEAL_COMMENT);
         long dealType = HistoryDealGetInteger(d, DEAL_TYPE);
         type = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      }
      else if(entry == DEAL_ENTRY_OUT)
      {
         dealOut = d;
         timeOut = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         profit += HistoryDealGetDouble(d, DEAL_PROFIT);
         commission += HistoryDealGetDouble(d, DEAL_COMMISSION);
         swap += HistoryDealGetDouble(d, DEAL_SWAP);
      }
   }

   // Lấy SL/TP từ lịch sử Order (vì Position đã đóng)
   if(HistorySelect(timeIn, timeOut + 1))
   {
      int totalOrders = HistoryOrdersTotal();
      for(int i = 0; i < totalOrders; i++)
      {
         ulong o = HistoryOrderGetTicket(i);
         if(HistoryOrderGetInteger(o, ORDER_POSITION_ID) == (long)ticket)
         {
            sl = HistoryOrderGetDouble(o, ORDER_SL);
            tp = HistoryOrderGetDouble(o, ORDER_TP);
            break;
         }
      }
   }

   // Format CSV line
   string timeframe = EnumToString((ENUM_TIMEFRAMES)Period());
   double finalProfit = profit + commission + swap;
   long duration = (timeIn > 0) ? (long)(timeOut - timeIn) : 0;

   int fileHandle = FileOpen(InpExportFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(fileHandle != INVALID_HANDLE)
   {
      FileSeek(fileHandle, 0, SEEK_END);
      if(FileSize(fileHandle) == 0)
      {
         // Ghi header nếu file mới
         FileWrite(fileHandle, "TimeIn", "Type", "Profit", "SL", "TP", "Symbol", "Timeframe", "Duration(s)", "Comment/Magic");
      }
      
      // Ghi dữ liệu
      FileWrite(fileHandle, 
                TimeToString(timeIn, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                type, 
                DoubleToString(finalProfit, 2), 
                DoubleToString(sl, _Digits), 
                DoubleToString(tp, _Digits), 
                symbol, 
                timeframe, 
                IntegerToString(duration), 
                comment + "/" + IntegerToString(InpMagicNumber));
                
      FileClose(fileHandle);
      Print(">>> Đã ghi lịch sử lệnh #", ticket, " vào file: MQL5\\Files\\", InpExportFileName);
   }
   else
   {
      Print("LỖI: Không thể mở file CSV để ghi. Mã lỗi: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Check if a specific ticket just closed and return closure reason  |
//| 0: Not closed, 1: Closed by TP, 2: Closed by other                |
//+------------------------------------------------------------------+
int GetPositionClosureState(ulong ticket)
{
   if(ticket == 0) return 0;
   if(PositionExists(ticket)) return 0;

   // Position is closed - check history for reason
   if(HistorySelectByPosition(ticket))
   {
      for(int d = HistoryDealsTotal()-1; d >= 0; d--)
      {
         ulong dt = HistoryDealGetTicket(d);
         if(dt == 0) continue;
         if(HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            if(HistoryDealGetInteger(dt, DEAL_REASON) == DEAL_REASON_TP)
               return 1; // TP
            else
               return 2; // Other (SL, Manual, etc.)
         }
      }
   }
   return 2; // Closed but reason not found
}

//+------------------------------------------------------------------+
//| Check all positions closed                                        |
//+------------------------------------------------------------------+
bool AllPositionsClosed()
{
   bool anyEntry = (g_lv34.state == LV_DONE || g_lv89.state == LV_DONE || g_lv200.state == LV_DONE);
   if(!anyEntry) return false;

   bool has34  = PositionExists(g_lv34.ticket);
   bool has89  = PositionExists(g_lv89.ticket);
   bool has200 = PositionExists(g_lv200.ticket);

   return (anyEntry && !has34 && !has89 && !has200);
}

//+------------------------------------------------------------------+
//| Process a single level for BUY direction (called on new bar)      |
//| emaVal = EMA value to touch, slPrice = price for SL,              |
//| rrMultiple = R:R ratio, label = comment                           |
//+------------------------------------------------------------------+
void ProcessBuyLevel(SLevel &lv, double emaVal, double slPrice, double rrMultiple, string label)
{
   double barLow  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double barHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);

   if(lv.state == LV_WAIT_TOUCH)
   {
      // Check if bar[1] low touched EMA
      if(barLow <= emaVal)
      {
         lv.state      = LV_WAIT_CONFIRM;
         lv.waitBars   = 0;
         lv.clusterLow = barLow;
         Print(label, " TOUCHED | Bar Low=", barLow, " EMA=", emaVal);

         if(HasBullishConfirm(1))
         {
            double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl   = NP(slPrice);
            double risk = ask - sl;
            double tp   = NP(ask + risk * rrMultiple);
            double lots = CalcLotSize(risk);

            if(risk > 0 && OpenBuy(sl, tp, lots, label, lv.ticket))
            {
               lv.state = LV_DONE;
               Print(label, " CONFIRMED (same bar) | Lot=", lots, " SL=", sl, " Risk$=", InpRiskPerTrade, " TP=", tp);
            }
         }
      }
   }
   else if(lv.state == LV_WAIT_CONFIRM)
   {
      lv.waitBars++;
      lv.clusterLow = MathMin(lv.clusterLow, barLow);

      if(HasBullishConfirm(1))
      {
         double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl   = NP(slPrice);
         double risk = ask - sl;
         double tp   = NP(ask + risk * rrMultiple);
         double lots = CalcLotSize(risk);

         if(risk > 0 && OpenBuy(sl, tp, lots, label, lv.ticket))
         {
            lv.state = LV_DONE;
            Print(label, " CONFIRMED (bar ", lv.waitBars, ") | Lot=", lots, " SL=", sl, " Risk$=", InpRiskPerTrade, " TP=", tp);
         }
      }
      else if(lv.waitBars >= InpMaxWaitBars)
      {
         Print(label, " confirmation timeout after ", lv.waitBars, " bars. Reset touch.");
         lv.state = LV_WAIT_TOUCH;
         lv.clusterLow = DBL_MAX;
      }
   }
}

//+------------------------------------------------------------------+
//| Process a single level for SELL direction (called on new bar)     |
//+------------------------------------------------------------------+
void ProcessSellLevel(SLevel &lv, double emaVal, double slPrice, double rrMultiple, string label)
{
   double barLow  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double barHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);

   if(lv.state == LV_WAIT_TOUCH)
   {
      // Check if bar[1] high touched EMA
      if(barHigh >= emaVal)
      {
         lv.state       = LV_WAIT_CONFIRM;
         lv.waitBars    = 0;
         lv.clusterHigh = barHigh;
         Print(label, " TOUCHED | Bar High=", barHigh, " EMA=", emaVal);

         if(HasBearishConfirm(1))
         {
            double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl   = NP(slPrice);
            double risk = sl - bid;
            double tp   = NP(bid - risk * rrMultiple);
            double lots = CalcLotSize(risk);

            if(risk > 0 && OpenSell(sl, tp, lots, label, lv.ticket))
            {
               lv.state = LV_DONE;
               Print(label, " CONFIRMED (same bar) | Lot=", lots, " SL=", sl, " Risk$=", InpRiskPerTrade, " TP=", tp);
            }
         }
      }
   }
   else if(lv.state == LV_WAIT_CONFIRM)
   {
      lv.waitBars++;
      lv.clusterHigh = MathMax(lv.clusterHigh, barHigh);

      if(HasBearishConfirm(1))
      {
         double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl   = NP(slPrice);
         double risk = sl - bid;
         double tp   = NP(bid - risk * rrMultiple);
         double lots = CalcLotSize(risk);

         if(risk > 0 && OpenSell(sl, tp, lots, label, lv.ticket))
         {
            lv.state = LV_DONE;
            Print(label, " CONFIRMED (bar ", lv.waitBars, ") | Lot=", lots, " SL=", sl, " Risk$=", InpRiskPerTrade, " TP=", tp);
         }
      }
      else if(lv.waitBars >= InpMaxWaitBars)
      {
         Print(label, " confirmation timeout after ", lv.waitBars, " bars. Reset touch.");
         lv.state = LV_WAIT_TOUCH;
         lv.clusterHigh = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_hEMA34  = iMA(_Symbol, PERIOD_CURRENT, InpPeriodFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA89  = iMA(_Symbol, PERIOD_CURRENT, InpPeriodMid,  0, MODE_EMA, PRICE_CLOSE);
   g_hEMA200 = iMA(_Symbol, PERIOD_CURRENT, InpPeriodSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hEMA34 == INVALID_HANDLE || g_hEMA89 == INVALID_HANDLE || g_hEMA200 == INVALID_HANDLE)
   {
      Print("ERROR: Cannot create EMA indicators!");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   ResetState();
   Print("EMA Pullback EA v2.0 (Price Action) initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEMA34  != INVALID_HANDLE) IndicatorRelease(g_hEMA34);
   if(g_hEMA89  != INVALID_HANDLE) IndicatorRelease(g_hEMA89);
   if(g_hEMA200 != INVALID_HANDLE) IndicatorRelease(g_hEMA200);
   Comment("");
   Print("EMA Pullback EA removed");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Get EMA values (bar[0] and bar[1])
   double ema34[2], ema89[2], ema200[2];
   if(CopyBuffer(g_hEMA34,  0, 0, 2, ema34)  < 2) return;
   if(CopyBuffer(g_hEMA89,  0, 0, 2, ema89)  < 2) return;
   if(CopyBuffer(g_hEMA200, 0, 0, 2, ema200) < 2) return;
   ArraySetAsSeries(ema34,  true);
   ArraySetAsSeries(ema89,  true);
   ArraySetAsSeries(ema200, true);

   //--- Monitor individual closures and log to CSV immediately
   bool tpTriggered = false;
   ulong tickets[3] = {g_lv34.ticket, g_lv89.ticket, g_lv200.ticket};
   
   for(int i = 0; i < 3; i++)
   {
      if(tickets[i] == 0) continue;
      
      int closureState = GetPositionClosureState(tickets[i]);
      if(closureState > 0)
      {
         Print(">>> Position #", tickets[i], " closed. Recording to CSV... <<<");
         ExportTradeToCSV(tickets[i]);
         
         if(closureState == 1) tpTriggered = true; // Was a TP

         // Clear the ticket so we don't process it again
         if(i == 0) g_lv34.ticket  = 0;
         if(i == 1) g_lv89.ticket  = 0;
         if(i == 2) g_lv200.ticket = 0;
      }
   }

   //--- If any position hit TP, close all remaining and reset cycle
   if(tpTriggered)
   {
      Print(">>> TP detected! Closing all remaining positions <<<");
      CloseAllPositions();
      ResetState();
      return;
   }

   //--- If all positions are gone (e.g. all hit SL), reset state
   if((g_lv34.state == LV_DONE || g_lv89.state == LV_DONE || g_lv200.state == LV_DONE) && AllPositionsClosed())
   {
      Print(">>> All positions closed (SL or Manual). Resetting state... <<<");
      ResetState();
      return;
   }

   //--- New bar processing
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime) 
   {
      DisplayInfo(ema34[0], ema89[0], ema200[0]);
      return;  // All logic below runs once per bar
   }
   g_lastBarTime = currentBarTime;

   //--- Setup detection (only when no direction)
   if(g_direction == DIR_NONE)
   {
      double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);

      if(prevClose > ema34[1] && prevClose > ema89[1] && prevClose > ema200[1]
         && ema34[1] > ema89[1] && ema89[1] > ema200[1])
      {
         g_direction  = DIR_BUY;
         g_setupValid = true;
         Print("*** BULLISH setup | EMA34=", ema34[1], " EMA89=", ema89[1],
               " EMA200=", ema200[1], " Close=", prevClose, " ***");
      }
      else if(prevClose < ema34[1] && prevClose < ema89[1] && prevClose < ema200[1]
              && ema34[1] < ema89[1] && ema89[1] < ema200[1])
      {
         g_direction  = DIR_SELL;
         g_setupValid = true;
         Print("*** BEARISH setup | EMA34=", ema34[1], " EMA89=", ema89[1],
               " EMA200=", ema200[1], " Close=", prevClose, " ***");
      }
   }
   else
   {
      // Invalidate if EMA alignment broken and no entries taken
      bool noEntries = (g_lv34.state != LV_DONE && g_lv89.state != LV_DONE && g_lv200.state != LV_DONE);
      if(noEntries)
      {
         if(g_direction == DIR_BUY && !(ema34[0] > ema89[0] && ema89[0] > ema200[0]))
         { Print("Bullish alignment broken. Reset."); ResetState(); return; }
         if(g_direction == DIR_SELL && !(ema34[0] < ema89[0] && ema89[0] < ema200[0]))
         { Print("Bearish alignment broken. Reset."); ResetState(); return; }
      }
   }

   //--- Process entry levels (sequential: 34 must be done/skipped before 89, etc.)
   if(!g_setupValid) { DisplayInfo(ema34[0], ema89[0], ema200[0]); return; }

   if(g_direction == DIR_BUY)
   {
      // Level 34: SL at EMA89
      if(InpUseEMA34 && g_lv34.state != LV_DONE)
         ProcessBuyLevel(g_lv34, ema34[1], ema89[1], 1.0, "EMA34_BUY");
      else if(!InpUseEMA34)
         g_lv34.state = LV_DONE;

      // Level 89: SL at EMA200
      if(InpUseEMA89 && g_lv34.state == LV_DONE && g_lv89.state != LV_DONE)
         ProcessBuyLevel(g_lv89, ema89[1], ema200[1], 2.0, "EMA89_BUY");
      else if(!InpUseEMA89)
         g_lv89.state = LV_DONE;

      // Level 200: SL at Cluster Low
      if(InpUseEMA200 && g_lv89.state == LV_DONE && g_lv200.state != LV_DONE)
      {
         double sl = (g_lv200.clusterLow != DBL_MAX) ? g_lv200.clusterLow : iLow(_Symbol, PERIOD_CURRENT, 1);
         ProcessBuyLevel(g_lv200, ema200[1], sl - InpSL_Buffer, 3.0, "EMA200_BUY");
      }
      else if(!InpUseEMA200)
         g_lv200.state = LV_DONE;
   }
   else if(g_direction == DIR_SELL)
   {
      // Level 34: SL at EMA89
      if(InpUseEMA34 && g_lv34.state != LV_DONE)
         ProcessSellLevel(g_lv34, ema34[1], ema89[1], 1.0, "EMA34_SELL");
      else if(!InpUseEMA34)
         g_lv34.state = LV_DONE;

      // Level 89: SL at EMA200
      if(InpUseEMA89 && g_lv34.state == LV_DONE && g_lv89.state != LV_DONE)
         ProcessSellLevel(g_lv89, ema89[1], ema200[1], 2.0, "EMA89_SELL");
      else if(!InpUseEMA89)
         g_lv89.state = LV_DONE;

      // Level 200: SL at Cluster High
      if(InpUseEMA200 && g_lv89.state == LV_DONE && g_lv200.state != LV_DONE)
      {
         double sl = (g_lv200.clusterHigh != 0) ? g_lv200.clusterHigh : iHigh(_Symbol, PERIOD_CURRENT, 1);
         ProcessSellLevel(g_lv200, ema200[1], sl + InpSL_Buffer, 3.0, "EMA200_SELL");
      }
      else if(!InpUseEMA200)
         g_lv200.state = LV_DONE;
   }

   DisplayInfo(ema34[0], ema89[0], ema200[0]);
}

//+------------------------------------------------------------------+
//| Get state label for display                                       |
//+------------------------------------------------------------------+
string StateStr(SLevel &lv)
{
   if(lv.state == LV_WAIT_TOUCH)   return "○ Wait Touch";
   if(lv.state == LV_WAIT_CONFIRM) return "◐ Wait Confirm (" + IntegerToString(lv.waitBars) + "/" + IntegerToString(InpMaxWaitBars) + ")";
   if(lv.state == LV_DONE)         return "✓ ENTERED";
   return "?";
}

//+------------------------------------------------------------------+
//| Display info on chart                                             |
//+------------------------------------------------------------------+
void DisplayInfo(double ema34, double ema89, double ema200)
{
   string dirStr = "NONE";
   if(g_direction == DIR_BUY)  dirStr = "BUY (Bullish)";
   if(g_direction == DIR_SELL) dirStr = "SELL (Bearish)";

   string info = "";
   info += "══════ EMA Pullback EA v2.0 ══════\n";
   info += "Mode: Price Action Confirmation\n";
   info += "Direction: " + dirStr + "\n";
   info += "─────────────────────────────\n";
   info += "EMA34:  " + DoubleToString(ema34,  _Digits) + " | " + StateStr(g_lv34)  + "\n";
   info += "EMA89:  " + DoubleToString(ema89,  _Digits) + " | " + StateStr(g_lv89)  + "\n";
   info += "EMA200: " + DoubleToString(ema200, _Digits) + " | " + StateStr(g_lv200) + "\n";
   info += "─────────────────────────────\n";
   info += "Open Positions: " + IntegerToString(CountPositions()) + " / 3\n";
   info += "SL Buffer: $" + DoubleToString(InpSL_Buffer, 1) + "\n";

   Comment(info);
}
//+------------------------------------------------------------------+
