using BNet.Cafe.Server.Repositories;
using BNet.Cafe.Server.Services;
using Newtonsoft.Json;
using System;
using System.Configuration;
using System.Web;

namespace BNet.Cafe.Server.Ashx
{
    /// <summary>
    /// Create a WeChat Pay NATIVE (QR code) order for a walk-in guest.
    /// POST: computerName, amount (yuan, e.g. 10 or 10.5).
    /// Returns: { success, codeUrl, outTradeNo, amount, durationMinutes, computerName, message }
    /// The kiosk renders codeUrl as a QR code; the customer scans it with WeChat to pay.
    /// Payment status is checked by polling QueryWeChatPayOrderHandler.ashx (no public
    /// notify callback is needed, the cafe server sits on a LAN).
    /// Merchant credentials come from Web.config appSettings (WeChatPay_AppId / MchId / ApiKey),
    /// so each cafe fills in its own merchant account.
    /// </summary>
    public class CreateWeChatPayOrderHandler : IHttpHandler
    {
        public void ProcessRequest(HttpContext context)
        {
            context.Response.ContentType = "application/json";

            if (!context.Request.HttpMethod.Equals("POST", StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 405;
                SendResponse(context, false, "Invalid request method. Only POST is allowed.", null);
                return;
            }

            try
            {
                string computerName = context.Request.Form["computerName"];
                string amountRaw = context.Request.Form["amount"];

                if (string.IsNullOrWhiteSpace(computerName))
                {
                    SendResponse(context, false, "Computer name is required.", null);
                    return;
                }

                decimal amountYuan;
                if (!decimal.TryParse(amountRaw, out amountYuan) || amountYuan <= 0)
                {
                    SendResponse(context, false, "Invalid amount.", null);
                    return;
                }

                string appId = ConfigurationManager.AppSettings["WeChatPay_AppId"];
                string mchId = ConfigurationManager.AppSettings["WeChatPay_MchId"];
                string apiKey = ConfigurationManager.AppSettings["WeChatPay_ApiKey"];
                string notifyUrl = ConfigurationManager.AppSettings["WeChatPay_NotifyUrl"];

                if (string.IsNullOrWhiteSpace(appId) || string.IsNullOrWhiteSpace(mchId) ||
                    string.IsNullOrWhiteSpace(apiKey))
                {
                    SendResponse(context, false, "WeChat Pay is not configured. Ask the admin to fill in WeChatPay_AppId / MchId / ApiKey in Web.config.", null);
                    return;
                }
                if (string.IsNullOrWhiteSpace(notifyUrl))
                {
                    // notify_url is a required field for unifiedorder, but we poll orderquery
                    // instead, so it is never actually called. Default to the site root.
                    notifyUrl = context.Request.Url.GetLeftPart(UriPartial.Authority) + "/";
                }

                // Amount -> play time, using the cafe's own pricing table (set prices in RMB).
                int durationMinutes = PricingRates.CalculateDurationFromPrice((double)amountYuan, "GUEST / WALK-IN");
                if (durationMinutes <= 0)
                {
                    SendResponse(context, false, "This amount buys no play time. Check the pricing table.", null);
                    return;
                }

                int totalFeeFen = (int)Math.Round(amountYuan * 100m, MidpointRounding.AwayFromZero);
                if (totalFeeFen < 1)
                {
                    SendResponse(context, false, "Amount is too small (minimum 0.01 yuan).", null);
                    return;
                }

                string outTradeNo = WeChatPayHelper.GenerateOutTradeNo();
                string body = "网吧上机 " + computerName;
                string clientIp = NetworkUtility.GetLocalIPAddress();
                if (string.IsNullOrWhiteSpace(clientIp)) clientIp = "127.0.0.1";

                string codeUrl = WeChatPayHelper.CreateNativeOrder(
                    appId, mchId, apiKey, body, outTradeNo, totalFeeFen, notifyUrl, clientIp);

                var data = new
                {
                    codeUrl = codeUrl,
                    outTradeNo = outTradeNo,
                    amount = amountYuan,
                    durationMinutes = durationMinutes,
                    computerName = computerName
                };
                SendResponse(context, true, "Order created.", data);
            }
            catch (Exception ex)
            {
                SendResponse(context, false, "Failed to create WeChat Pay order: " + ex.Message, null);
            }
        }

        private void SendResponse(HttpContext context, bool success, string message, object data)
        {
            var payload = new { success = success, message = message, data = data };
            context.Response.Write(JsonConvert.SerializeObject(payload));
        }

        public bool IsReusable => false;
    }
}
