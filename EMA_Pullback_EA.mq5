//+------------------------------------------------------------------+
//|                                          EMA_Pullback_EA.mq5     |
//|                                          Copyright 2026, TamPV   |
//+------------------------------------------------------------------+
#property copyright "TamPV"
#property version   "3.00"
#property description "3 EMA Pullback + Price Action Confirmation"
#property description "Entry: Touch EMA -> Wait Pinbar/Engulfing -> Enter"
#property description "SL: Below/Above EMA Slow (Fast/Mid) or confirmation candle (Slow)"
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
input bool             InpUseEMA_Fast    = true;            // Enable Entry at Fast EMA
input bool             InpUseEMA_Mid     = true;            // Enable Entry at Mid EMA
input bool             InpUseEMA_Slow    = true;            // Enable Entry at Slow EMA
input double           InpRR_Fast        = 1.0;             // R:R Ratio for Fast EMA (Level 1)
input double           InpRR_Mid         = 2.0;             // R:R Ratio for Mid EMA (Level 2)
input double           InpRR_Slow        = 3.0;             // R:R Ratio for Slow EMA (Level 3)
input double           InpRiskPerTrade   = 50.0;            // Risk per trade ($)
input int              InpMaxWaitBars    = 5;               // Max bars to wait for confirmation
input int              InpMagicNumber    = 345890;          // Magic Number
input int              InpSlippage       = 30;              // Slippage (points)

input group "=== Pattern Detection ==="
input double           InpPinbarRatio    = 2.0;             // Pinbar: wick/body minimum ratio
input double           InpMinCandleRange = 1.0;             // Min candle range to qualify (price $)



input group "=== Trading Days ==="
input bool             InpTradeMonday    = true;            // Trade on Monday
input bool             InpTradeTuesday   = true;            // Trade on Tuesday
input bool             InpTradeWednesday = true;            // Trade on Wednesday
input bool             InpTradeThursday  = true;            // Trade on Thursday
input bool             InpTradeFriday    = true;            // Trade on Friday
input bool             InpTradeSaturday  = false;           // Trade on Saturday
input bool             InpTradeSunday    = false;           // Trade on Sunday

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
   ulong         ticket;        // Position ticket

   void Init()
   {
      state       = LV_WAIT_TOUCH;
      waitBars    = 0;
      ticket      = 0;
   }
};

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
int g_hEMA_Fast, g_hEMA_Mid, g_hEMA_Slow;
CTrade g_trade;

ENUM_DIR g_direction = DIR_NONE;
bool     g_setupValid = false;
SLevel   g_lvFast, g_lvMid, g_lvSlow;
datetime g_lastBarTime = 0;
string   g_exportFileName = "";

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

   // Round to nearest lot step (MathRound for accuracy, not MathFloor)
   lots = MathRound(lots / lotStep) * lotStep;

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

   // Calculate precision from lotStep (e.g. 0.01 -> 2, 0.001 -> 3)
   int lotDigits = (int)MathMax(-MathLog10(lotStep), 0);
   return NormalizeDouble(lots, lotDigits);
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
   g_lvFast.Init();
   g_lvMid.Init();
   g_lvSlow.Init();
}

//+------------------------------------------------------------------+
//| Check if trading is allowed on the current day of the week        |
//+------------------------------------------------------------------+
bool IsTradingDayAllowed()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   switch(dt.day_of_week)
   {
      case 0: return InpTradeSunday;
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      case 6: return InpTradeSaturday;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open BUY                                                          |
//+------------------------------------------------------------------+
bool OpenBuy(double sl, double tp, double lots, string comment, ulong &ticket, double entryPrice)
{
   if(!IsTradingDayAllowed())
      return false;

   sl = NP(sl); tp = NP(tp);
   if(lots <= 0) { return false; }
   if(g_trade.Buy(lots, _Symbol, entryPrice, sl, tp, comment))
   {
      ticket = g_trade.ResultOrder();
      return true;
   }
   Print("BUY FAILED: ", comment, " Lot=", lots, " Err=", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Open SELL                                                         |
//+------------------------------------------------------------------+
bool OpenSell(double sl, double tp, double lots, string comment, ulong &ticket, double entryPrice)
{
   if(!IsTradingDayAllowed())
      return false;

   sl = NP(sl); tp = NP(tp);
   if(lots <= 0) { return false; }
   if(g_trade.Sell(lots, _Symbol, entryPrice, sl, tp, comment))
   {
      ticket = g_trade.ResultOrder();
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
   // Do HistorySelectByPosition(ticket) đã được chọn ở trên, các orders liên quan đều có sẵn
   int totalOrders = HistoryOrdersTotal();
   for(int i = 0; i < totalOrders; i++)
   {
      ulong o = HistoryOrderGetTicket(i);
      if(HistoryOrderGetInteger(o, ORDER_POSITION_ID) == (long)ticket)
      {
         sl = HistoryOrderGetDouble(o, ORDER_SL);
         tp = HistoryOrderGetDouble(o, ORDER_TP);
         if(sl > 0 || tp > 0) break;
      }
   }

   // Format CSV line
   string timeframe = EnumToString((ENUM_TIMEFRAMES)Period());
   double finalProfit = profit + commission + swap;
   long duration = (timeIn > 0) ? (long)(timeOut - timeIn) : 0;

   int fileHandle = FileOpen(g_exportFileName, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(fileHandle != INVALID_HANDLE)
   {
      FileSeek(fileHandle, 0, SEEK_END);
      if(FileSize(fileHandle) == 0)
      {
         // Ghi header nếu file mới
         string header = "\"TimeIn\",\"Type\",\"Volume\",\"Profit\",\"SL\",\"TP\",\"Symbol\",\"Timeframe\",\"Duration(s)\",\"EMA\",\"Magic\"";
         FileWriteString(fileHandle, header + "\r\n");
      }
      
      // Ghi dữ liệu - các cột ngăn cách bằng dấu phẩy, giá trị bọc trong ngoặc kép
      string line = "\"" + TimeToString(timeIn, TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\","
                  + "\"" + type + "\","
                  + "\"" + DoubleToString(lots, 2) + "\","
                  + "\"" + DoubleToString(finalProfit, 2) + "\","
                  + "\"" + DoubleToString(sl, _Digits) + "\","
                  + "\"" + DoubleToString(tp, _Digits) + "\","
                  + "\"" + symbol + "\","
                  + "\"" + timeframe + "\","
                  + "\"" + IntegerToString(duration) + "\","
                  + "\"" + comment + "\","
                  + "\"" + IntegerToString(InpMagicNumber) + "\"";
      FileWriteString(fileHandle, line + "\r\n");
                
      FileClose(fileHandle);
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
   bool anyEntry = (g_lvFast.state == LV_DONE || g_lvMid.state == LV_DONE || g_lvSlow.state == LV_DONE);
   if(!anyEntry) return false;

   // Check if any entered position is still active
   if(g_lvFast.state == LV_DONE && PositionExists(g_lvFast.ticket)) return false;
   if(g_lvMid.state == LV_DONE && PositionExists(g_lvMid.ticket)) return false;
   if(g_lvSlow.state == LV_DONE && PositionExists(g_lvSlow.ticket)) return false;

   // If setup invalid (e.g. EMA alignment broken), reset when all entered positions closed
   if(!g_setupValid) return true;

   // If setup still valid, wait for all enabled levels to complete
   if(InpUseEMA_Fast && g_lvFast.state != LV_DONE) return false;
   if(InpUseEMA_Mid  && g_lvMid.state  != LV_DONE) return false;
   if(InpUseEMA_Slow && g_lvSlow.state != LV_DONE) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Process a single level for BUY direction (called on new bar)      |
//| emaVal = EMA value to touch, slPrice = price for SL,              |
//| rrMultiple = R:R ratio, label = comment                           |
//+------------------------------------------------------------------+
void ProcessBuyLevel(SLevel &lv, double emaVal, double slPrice, double rrMultiple, string label)
{
   double barLow   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double barHigh  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double barClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(lv.state == LV_WAIT_TOUCH)
   {
      // Check if bar[1] pulled back to touch EMA and closed above it (true pullback)
      if(barLow <= emaVal && barClose > emaVal)
      {
         lv.state    = LV_WAIT_CONFIRM;
         lv.waitBars = 0;

         if(HasBullishConfirm(1))
         {
            double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl   = NP(slPrice);
            double risk = ask - sl;
            double tp   = NP(ask + risk * rrMultiple);
            double lots = CalcLotSize(risk);

            if(risk > 0 && OpenBuy(sl, tp, lots, label, lv.ticket, ask))
            {
               lv.state = LV_DONE;
            }
         }
      }
   }
   else if(lv.state == LV_WAIT_CONFIRM)
   {
      lv.waitBars++;

      if(HasBullishConfirm(1))
      {
         double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl   = NP(slPrice);
         double risk = ask - sl;
         double tp   = NP(ask + risk * rrMultiple);
         double lots = CalcLotSize(risk);

         if(risk > 0 && OpenBuy(sl, tp, lots, label, lv.ticket, ask))
         {
            lv.state = LV_DONE;
         }
      }
      else if(lv.waitBars >= InpMaxWaitBars)
      {
         lv.state = LV_WAIT_TOUCH;
      }
   }
}

//+------------------------------------------------------------------+
//| Process a single level for SELL direction (called on new bar)     |
//+------------------------------------------------------------------+
void ProcessSellLevel(SLevel &lv, double emaVal, double slPrice, double rrMultiple, string label)
{
   double barLow   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double barHigh  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double barClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(lv.state == LV_WAIT_TOUCH)
   {
      // Check if bar[1] pulled back to touch EMA and closed below it (true pullback)
      if(barHigh >= emaVal && barClose < emaVal)
      {
         lv.state    = LV_WAIT_CONFIRM;
         lv.waitBars = 0;

         if(HasBearishConfirm(1))
         {
            double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl   = NP(slPrice);
            double risk = sl - bid;
            double tp   = NP(bid - risk * rrMultiple);
            double lots = CalcLotSize(risk);

            if(risk > 0 && OpenSell(sl, tp, lots, label, lv.ticket, bid))
            {
               lv.state = LV_DONE;
            }
         }
      }
   }
   else if(lv.state == LV_WAIT_CONFIRM)
   {
      lv.waitBars++;

      if(HasBearishConfirm(1))
      {
         double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl   = NP(slPrice);
         double risk = sl - bid;
         double tp   = NP(bid - risk * rrMultiple);
         double lots = CalcLotSize(risk);

         if(risk > 0 && OpenSell(sl, tp, lots, label, lv.ticket, bid))
         {
            lv.state = LV_DONE;
         }
      }
      else if(lv.waitBars >= InpMaxWaitBars)
      {
         lv.state = LV_WAIT_TOUCH;
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_hEMA_Fast = iMA(_Symbol, PERIOD_CURRENT, InpPeriodFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA_Mid  = iMA(_Symbol, PERIOD_CURRENT, InpPeriodMid,  0, MODE_EMA, PRICE_CLOSE);
   g_hEMA_Slow = iMA(_Symbol, PERIOD_CURRENT, InpPeriodSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hEMA_Fast == INVALID_HANDLE || g_hEMA_Mid == INVALID_HANDLE || g_hEMA_Slow == INVALID_HANDLE)
   {
      Print("ERROR: Cannot create EMA indicators!");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Auto-generate export filename: e.g. BTCUSD_M15.csv
   string tf = EnumToString((ENUM_TIMEFRAMES)Period());
   StringReplace(tf, "PERIOD_", "");
   g_exportFileName = _Symbol + "_" + tf + ".csv";

   ResetState();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEMA_Fast != INVALID_HANDLE) IndicatorRelease(g_hEMA_Fast);
   if(g_hEMA_Mid  != INVALID_HANDLE) IndicatorRelease(g_hEMA_Mid);
   if(g_hEMA_Slow != INVALID_HANDLE) IndicatorRelease(g_hEMA_Slow);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Get EMA values (bar[0] and bar[1])
   double emaFast[2], emaMid[2], emaSlow[2];
   if(CopyBuffer(g_hEMA_Fast,  0, 0, 2, emaFast)  < 2) return;
   if(CopyBuffer(g_hEMA_Mid,   0, 0, 2, emaMid)   < 2) return;
   if(CopyBuffer(g_hEMA_Slow,  0, 0, 2, emaSlow)  < 2) return;
   ArraySetAsSeries(emaFast,  true);
   ArraySetAsSeries(emaMid,   true);
   ArraySetAsSeries(emaSlow,  true);

   //--- Monitor individual closures and log to CSV immediately
   bool tpTriggered = false;
   ulong tickets[3] = {g_lvFast.ticket, g_lvMid.ticket, g_lvSlow.ticket};
   
   for(int i = 0; i < 3; i++)
   {
      if(tickets[i] == 0) continue;
      
      int closureState = GetPositionClosureState(tickets[i]);
      if(closureState > 0)
      {
         ExportTradeToCSV(tickets[i]);
         
         if(closureState == 1) tpTriggered = true; // Was a TP

         // Clear the ticket so we don't process it again
         if(i == 0) g_lvFast.ticket = 0;
         if(i == 1) g_lvMid.ticket  = 0;
         if(i == 2) g_lvSlow.ticket = 0;
      }
   }

   //--- If any position hit TP, close all remaining and reset cycle
   if(tpTriggered)
   {
      CloseAllPositions();
      g_setupValid = false; // Ngăn chặn mở thêm lệnh mới cho chu kỳ này để chờ các lệnh đóng hết và ghi log xong
      return;
   }

   //--- If all positions are gone (e.g. all hit SL), reset state
   if((g_lvFast.state == LV_DONE || g_lvMid.state == LV_DONE || g_lvSlow.state == LV_DONE) && AllPositionsClosed())
   {
      ResetState();
      return;
   }

   //--- New bar processing
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime) 
   {
      DisplayInfo(emaFast[0], emaMid[0], emaSlow[0]);
      return;  // All logic below runs once per bar
   }
   g_lastBarTime = currentBarTime;

   //--- Setup detection (only when no direction)
   if(g_direction == DIR_NONE)
   {
      double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);

      if(prevClose > emaFast[1] && prevClose > emaMid[1] && prevClose > emaSlow[1]
         && emaFast[1] > emaMid[1] && emaMid[1] > emaSlow[1])
      {
         g_direction  = DIR_BUY;
         g_setupValid = true;
      }
      else if(prevClose < emaFast[1] && prevClose < emaMid[1] && prevClose < emaSlow[1]
              && emaFast[1] < emaMid[1] && emaMid[1] < emaSlow[1])
      {
         g_direction  = DIR_SELL;
         g_setupValid = true;
      }
   }
   else
   {
      // Check EMA alignment — invalidate setup if alignment broken
      bool alignmentBroken = false;
      if(g_direction == DIR_BUY && !(emaFast[0] > emaMid[0] && emaMid[0] > emaSlow[0]))
         alignmentBroken = true;
      if(g_direction == DIR_SELL && !(emaFast[0] < emaMid[0] && emaMid[0] < emaSlow[0]))
         alignmentBroken = true;

      if(alignmentBroken)
      {
         bool noEntries = (g_lvFast.state != LV_DONE && g_lvMid.state != LV_DONE && g_lvSlow.state != LV_DONE);
         if(noEntries)
         {
            ResetState();
            return;
         }
         else
         {
            g_setupValid = false;
         }
      }
   }

   //--- Process entry levels (independent per EMA)
   if(!g_setupValid) { DisplayInfo(emaFast[0], emaMid[0], emaSlow[0]); return; }

   if(g_direction == DIR_BUY)
   {
      // Fast Level: SL at Slow EMA
      if(InpUseEMA_Fast && g_lvFast.state != LV_DONE)
         ProcessBuyLevel(g_lvFast, emaFast[1], emaSlow[1], InpRR_Fast, "EMA" + IntegerToString(InpPeriodFast) + "_BUY");

      // Mid Level: SL at Slow EMA (independent entry)
      if(InpUseEMA_Mid && g_lvMid.state != LV_DONE)
         ProcessBuyLevel(g_lvMid, emaMid[1], emaSlow[1], InpRR_Mid, "EMA" + IntegerToString(InpPeriodMid) + "_BUY");

      // Slow Level: SL at confirmation candle low
      if(InpUseEMA_Slow && g_lvSlow.state != LV_DONE)
      {
         double slPrice = iLow(_Symbol, PERIOD_CURRENT, 1);
         ProcessBuyLevel(g_lvSlow, emaSlow[1], slPrice, InpRR_Slow, "EMA" + IntegerToString(InpPeriodSlow) + "_BUY");
      }
   }
   else if(g_direction == DIR_SELL)
   {
      // Fast Level: SL at Slow EMA
      if(InpUseEMA_Fast && g_lvFast.state != LV_DONE)
         ProcessSellLevel(g_lvFast, emaFast[1], emaSlow[1], InpRR_Fast, "EMA" + IntegerToString(InpPeriodFast) + "_SELL");

      // Mid Level: SL at Slow EMA (independent entry)
      if(InpUseEMA_Mid && g_lvMid.state != LV_DONE)
         ProcessSellLevel(g_lvMid, emaMid[1], emaSlow[1], InpRR_Mid, "EMA" + IntegerToString(InpPeriodMid) + "_SELL");

      // Slow Level: SL at confirmation candle high
      if(InpUseEMA_Slow && g_lvSlow.state != LV_DONE)
      {
         double slPrice = iHigh(_Symbol, PERIOD_CURRENT, 1);
         ProcessSellLevel(g_lvSlow, emaSlow[1], slPrice, InpRR_Slow, "EMA" + IntegerToString(InpPeriodSlow) + "_SELL");
      }
   }

   DisplayInfo(emaFast[0], emaMid[0], emaSlow[0]);
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
void DisplayInfo(double emaFast, double emaMid, double emaSlow)
{
   string dirStr = "NONE";
   if(g_direction == DIR_BUY)  dirStr = "BUY (Bullish)";
   if(g_direction == DIR_SELL) dirStr = "SELL (Bearish)";

   string info = "";
   info += "══════ EMA Pullback EA v3.0 ══════\n";
   info += "Mode: Price Action Confirmation\n";
   info += "Direction: " + dirStr + "\n";
   info += "─────────────────────────────\n";
   info += "EMA" + IntegerToString(InpPeriodFast) + ":  " + DoubleToString(emaFast, _Digits) + " | " + StateStr(g_lvFast)  + "\n";
   info += "EMA" + IntegerToString(InpPeriodMid) + ":  " + DoubleToString(emaMid,  _Digits) + " | " + StateStr(g_lvMid)   + "\n";
   info += "EMA" + IntegerToString(InpPeriodSlow) + ": " + DoubleToString(emaSlow, _Digits) + " | " + StateStr(g_lvSlow)  + "\n";
   info += "─────────────────────────────\n";
   info += "Open Positions: " + IntegerToString(CountPositions()) + " / 3\n";

   Comment(info);
}
//+------------------------------------------------------------------+
