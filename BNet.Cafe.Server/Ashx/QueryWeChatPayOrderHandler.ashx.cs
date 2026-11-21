using BNet.Cafe.Server.Services;
using Newtonsoft.Json;
using System;
using System.Configuration;
using System.Web;

namespace BNet.Cafe.Server.Ashx
{
    /// <summary>
    /// Poll a WeChat Pay order's payment status.
    /// GET/POST: outTradeNo.
    /// Returns: { success, paid, tradeState, message }
    /// tradeState: SUCCESS = paid, NOTPAY = not paid yet, USERPAYING = paying,
    /// CLOSED / REVOKED / PAYERROR = failed. The kiosk polls this every few seconds
    /// until the customer pays or the QR code expires.
    /// </summary>
    public class QueryWeChatPayOrderHandler : IHttpHandler
    {
        public void ProcessRequest(HttpContext context)
        {
            context.Response.ContentType = "application/json";

            try
            {
                string outTradeNo = context.Request["outTradeNo"];
                if (string.IsNullOrWhiteSpace(outTradeNo))
                {
                    SendResponse(context, false, false, "", "outTradeNo is required.");
                    return;
                }

                string appId = ConfigurationManager.AppSettings["WeChatPay_AppId"];
                string mchId = ConfigurationManager.AppSettings["WeChatPay_MchId"];
                string apiKey = ConfigurationManager.AppSettings["WeChatPay_ApiKey"];

                if (string.IsNullOrWhiteSpace(appId) || string.IsNullOrWhiteSpace(mchId) ||
                    string.IsNullOrWhiteSpace(apiKey))
                {
                    SendResponse(context, false, false, "", "WeChat Pay is not configured.");
                    return;
                }

                string tradeState = WeChatPayHelper.QueryOrderTradeState(appId, mchId, apiKey, outTradeNo);
                bool paid = string.Equals(tradeState, "SUCCESS", StringComparison.OrdinalIgnoreCase);
                SendResponse(context, true, paid, tradeState, paid ? "Paid." : "Not paid yet (" + tradeState + ").");
            }
            catch (Exception ex)
            {
                SendResponse(context, false, false, "", "Query failed: " + ex.Message);
            }
        }

        private void SendResponse(HttpContext context, bool success, bool paid, string tradeState, string message)
        {
            var payload = new { success = success, paid = paid, tradeState = tradeState, message = message };
            context.Response.Write(JsonConvert.SerializeObject(payload));
        }

        public bool IsReusable => false;
    }
}
