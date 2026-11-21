using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Xml;

namespace BNet.Cafe.Server.Services
{
    /// <summary>
    /// WeChat Pay v2 (NATIVE / scan-to-pay) helper.
    /// Each cafe configures its own merchant credentials in Web.config appSettings:
    ///   WeChatPay_AppId, WeChatPay_MchId, WeChatPay_ApiKey, WeChatPay_NotifyUrl
    /// The server polls orderquery for payment status (the cafe server sits on a LAN
    /// and cannot receive WeChat's notify callback), so no public callback URL is needed.
    /// </summary>
    public static class WeChatPayHelper
    {
        public const string UnifiedOrderUrl = "https://api.mch.weixin.qq.com/pay/unifiedorder";
        public const string OrderQueryUrl = "https://api.mch.weixin.qq.com/pay/orderquery";

        private static readonly Random Random = new Random();

        /// <summary>32-char random alphanumeric nonce string.</summary>
        public static string GenerateNonceStr()
        {
            const string chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
            var sb = new StringBuilder(32);
            lock (Random)
            {
                for (int i = 0; i < 32; i++)
                {
                    sb.Append(chars[Random.Next(chars.Length)]);
                }
            }
            return sb.ToString();
        }

        /// <summary>
        /// Merchant order number, max 32 chars, unique per order.
        /// Format: BN + yyyyMMddHHmmss + 6 random digits (e.g. BN20261121153000123456).
        /// </summary>
        public static string GenerateOutTradeNo()
        {
            string ts = DateTime.Now.ToString("yyyyMMddHHmmss");
            int rnd;
            lock (Random)
            {
                rnd = Random.Next(100000, 999999);
            }
            return "BN" + ts + rnd;
        }

        /// <summary>
        /// WeChat Pay v2 MD5 signature: sort params by ASCII key, skip empty values
        /// and the "sign" key, join as k=v with '&amp;', append "&amp;key=API_KEY", MD5, uppercase.
        /// </summary>
        public static string Sign(IDictionary<string, string> parameters, string apiKey)
        {
            var sorted = parameters
                .Where(kv => !string.IsNullOrEmpty(kv.Value) && kv.Key != "sign")
                .OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .Select(kv => kv.Key + "=" + kv.Value);
            string stringA = string.Join("&", sorted);
            string stringSignTemp = stringA + "&key=" + apiKey;
            using (MD5 md5 = MD5.Create())
            {
                byte[] hash = md5.ComputeHash(Encoding.UTF8.GetBytes(stringSignTemp));
                var sb = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash)
                {
                    sb.Append(b.ToString("x2"));
                }
                return sb.ToString().ToUpperInvariant();
            }
        }

        /// <summary>Build &lt;xml&gt;...&lt;/xml&gt; request body. Values are wrapped in CDATA.</summary>
        public static string ToXml(IDictionary<string, string> parameters)
        {
            var sb = new StringBuilder();
            sb.Append("<xml>");
            foreach (var kv in parameters)
            {
                if (string.IsNullOrEmpty(kv.Value)) continue;
                sb.Append("<").Append(kv.Key).Append("><![CDATA[")
                  .Append(kv.Value)
                  .Append("]]></").Append(kv.Key).Append(">");
            }
            sb.Append("</xml>");
            return sb.ToString();
        }

        /// <summary>Parse a WeChat &lt;xml&gt; response into a flat dictionary.</summary>
        public static Dictionary<string, string> ParseXml(string xml)
        {
            var result = new Dictionary<string, string>();
            if (string.IsNullOrWhiteSpace(xml)) return result;
            var doc = new XmlDocument();
            doc.LoadXml(xml);
            XmlNode root = doc.SelectSingleNode("xml");
            if (root == null) return result;
            foreach (XmlNode node in root.ChildNodes)
            {
                result[node.Name] = node.InnerText;
            }
            return result;
        }

        /// <summary>POST an XML body, return the raw XML response string.</summary>
        public static string PostXml(string url, string xml, int timeoutMs = 15000)
        {
            byte[] data = Encoding.UTF8.GetBytes(xml);
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "POST";
            request.ContentType = "text/xml; charset=utf-8";
            request.ContentLength = data.Length;
            request.Timeout = timeoutMs;
            using (Stream stream = request.GetRequestStream())
            {
                stream.Write(data, 0, data.Length);
            }
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                return reader.ReadToEnd();
            }
        }

        /// <summary>
        /// Create a NATIVE (QR code) order. Returns the code_url to render as a QR code.
        /// totalFeeFen is the amount in fen (1 yuan = 100 fen).
        /// Throws on communication failure or a WeChat-side error (return_code/result_code != SUCCESS).
        /// </summary>
        public static string CreateNativeOrder(string appId, string mchId, string apiKey,
            string body, string outTradeNo, int totalFeeFen, string notifyUrl, string clientIp)
        {
            var parameters = new Dictionary<string, string>
            {
                { "appid", appId },
                { "mch_id", mchId },
                { "nonce_str", GenerateNonceStr() },
                { "body", body },
                { "out_trade_no", outTradeNo },
                { "total_fee", totalFeeFen.ToString() },
                { "spbill_create_ip", clientIp },
                { "notify_url", notifyUrl },
                { "trade_type", "NATIVE" }
            };
            parameters["sign"] = Sign(parameters, apiKey);

            string responseXml = PostXml(UnifiedOrderUrl, ToXml(parameters));
            var result = ParseXml(responseXml);

            string returnCode;
            if (!result.TryGetValue("return_code", out returnCode) || returnCode != "SUCCESS")
            {
                string msg;
                result.TryGetValue("return_msg", out msg);
                throw new Exception("WeChat unifiedorder failed: " + (msg ?? responseXml));
            }
            string resultCode;
            if (!result.TryGetValue("result_code", out resultCode) || resultCode != "SUCCESS")
            {
                string errCode;
                string errDesc;
                result.TryGetValue("err_code", out errCode);
                result.TryGetValue("err_code_des", out errDesc);
                throw new Exception("WeChat unifiedorder error: " + errCode + " " + errDesc);
            }
            string codeUrl;
            if (!result.TryGetValue("code_url", out codeUrl) || string.IsNullOrEmpty(codeUrl))
            {
                throw new Exception("WeChat unifiedorder returned no code_url.");
            }
            return codeUrl;
        }

        /// <summary>
        /// Query an order's payment status. Returns the trade_state string:
        /// SUCCESS (paid), NOTPAY, USERPAYING, CLOSED, REVOKED, PAYERROR, or "" on error.
        /// </summary>
        public static string QueryOrderTradeState(string appId, string mchId, string apiKey, string outTradeNo)
        {
            var parameters = new Dictionary<string, string>
            {
                { "appid", appId },
                { "mch_id", mchId },
                { "nonce_str", GenerateNonceStr() },
                { "out_trade_no", outTradeNo }
            };
            parameters["sign"] = Sign(parameters, apiKey);

            string responseXml = PostXml(OrderQueryUrl, ToXml(parameters));
            var result = ParseXml(responseXml);

            string returnCode;
            if (!result.TryGetValue("return_code", out returnCode) || returnCode != "SUCCESS")
            {
                return "";
            }
            string resultCode;
            if (!result.TryGetValue("result_code", out resultCode) || resultCode != "SUCCESS")
            {
                return "";
            }
            string tradeState;
            result.TryGetValue("trade_state", out tradeState);
            return tradeState ?? "";
        }
    }
}
