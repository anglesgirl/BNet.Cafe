using BNet.Cafe.Server.Ashx;
using BNet.Cafe.Server.Services;
using System;
using System.Web.UI;

namespace BNet.Cafe.Server
{
    /// <summary>
    /// Kiosk / coinslot page (BNetVendoMachine.aspx).
    ///
    /// NOTE (fork, 2026-11-21): the upstream repository never committed this
    /// code-behind — it only exists as a compiled DLL in the author's
    /// deployment repo (BNet.Cafe.Timer). This is a clean-room reconstruction
    /// of the page's server-side behaviour, built from the .aspx markup and
    /// the existing handlers/services. It deliberately does NOT include the
    /// author's commercial license/trial system: this fork is free, so the
    /// activation button stays hidden and the license modal just says so.
    ///
    /// Coin flow (LinkButton_ProcessVendo_Click): the browser fills
    /// HiddenField_ModalAmount / HiddenField_ModalComputerName (see
    /// Assets/Vendo/Modals.js) and clicks the hidden LinkButton. The server
    /// converts the amount to minutes, writes a Rentals row and sends the
    /// unlock JSON to the target PC over the WebSocket server channel —
    /// exactly the same path the WeChat Pay flow uses
    /// (CreateWeChatPayOrderHandler + QueryWeChatPayOrderHandler).
    /// </summary>
    public partial class BNetVendoMachine : Page
    {
        protected void Page_Load(object sender, EventArgs e)
        {
            // No license check in this fork: the activation button and the
            // license modal stay hidden (Visible="false" in the markup).
            // Label_ComshopName keeps its markup default ("BNet Cafe").
        }

        protected void LinkButton_ProcessVendo_Click(object sender, EventArgs e)
        {
            string computerName = HiddenField_ModalComputerName.Value;
            string amountText = HiddenField_ModalAmount.Value;

            if (string.IsNullOrWhiteSpace(computerName) ||
                !decimal.TryParse(amountText, out decimal amount) || amount <= 0)
            {
                return;
            }

            // Amount -> minutes, using the same DB pricing intervals as the
            // CalculateDurationFromAmountHandler.
            int durationMinutes = CalculateDurationFromAmountHandler.CalculateDuration(amount);
            if (durationMinutes <= 0)
            {
                return;
            }

            // Walk-in guest: no user account, so userId is empty.
            var rentalHandler = new CreateRentalHandler();
            bool created = rentalHandler.Create(
                Context,
                computerName,
                string.Empty,
                durationMinutes.ToString(),
                amount.ToString());

            if (!created)
            {
                return;
            }

            // Unlock the PC: registers a startup script that calls the
            // browser-side sendTextMessageToPC(targetClient, jsonMessage),
            // which delivers the unlock JSON over /ws/server (opcode 0x02).
            RemoteMessagingService.SendToPC(
                this,
                computerName,
                string.Empty,
                durationMinutes,
                amount);
        }

        protected void LinkButton_ShowActivation_Click(object sender, EventArgs e)
        {
            // The button is Visible="false" in the markup; this only fires
            // if something shows it. Show the modal with the fork's message.
            Label_LicenseMessage.Text = "This fork is free and does not require a license.";
            licenseModal.Visible = true;
        }

        protected void LinkButton_ActivateLicense_Click(object sender, EventArgs e)
        {
            // No license system in this fork — nothing to activate.
            Label_LicenseMessage.Text = "This fork is free and does not require a license.";
            licenseModal.Visible = false;
        }
    }
}
