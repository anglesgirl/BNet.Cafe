// WeChat Pay (NATIVE scan-to-pay) for the BNet kiosk page.
// Replaces the coin slot for walk-in guests: the customer picks a PC and an amount,
// scans the QR code with WeChat, and the PC unlocks as soon as payment lands.
//
// Flow:
//   1. POST Ashx/CreateWeChatPayOrderHandler.ashx { computerName, amount }
//      -> { codeUrl, outTradeNo, durationMinutes }
//   2. Render codeUrl as a QR code, poll Ashx/QueryWeChatPayOrderHandler.ashx
//      every 2.5s until trade_state == SUCCESS (or 5 min timeout).
//   3. On success: POST Ashx/CreateRentalHandler.ashx (billing record) and
//      sendTextMessageToPC(pc, { userId, duration, amount }) over the existing
//      /ws/server channel (opcode 0x02) — the client PC unlocks exactly like
//      it does after a coin payment. No client changes needed.
//
// Merchant credentials are per-cafe, in Web.config appSettings
// (WeChatPay_AppId / MchId / ApiKey). Prices come from the cafe's own pricing
// table, so set the pricing table in RMB.
//
// Include this file in BNetVendoMachine.aspx after the other Vendo scripts.
// The QR code is rendered via api.qrserver.com (the kiosk needs internet,
// which WeChat Pay requires anyway); the raw code_url is shown as a fallback.

(function () {
    'use strict';

    var wxpayPollTimer = null;
    var wxpayCurrentOrder = null; // { outTradeNo, computerName, amount, durationMinutes }
    var wxpayCountdownTimer = null;
    var wxpayRemainingSeconds = 300; // QR code valid 5 minutes
    var wxpayQuickAmounts = [5, 10, 20, 30, 50, 100];

    // Resolve an .ashx endpoint relative to the current page, same pattern as Main.js.
    function wxpayEndpoint(handlerName) {
        return /\.aspx$/i.test(window.location.pathname)
            ? window.location.pathname.replace(/[^\/]+\.aspx$/i, 'Ashx/' + handlerName)
            : window.location.pathname.replace(/[^\/]+$/i, 'Ashx/' + handlerName);
    }

    function wxpaySelectedClient() {
        try {
            if (typeof filteredClientData !== 'undefined' && Array.isArray(filteredClientData) &&
                typeof selectedIndex === 'number' &&
                selectedIndex >= 0 && selectedIndex < filteredClientData.length) {
                return filteredClientData[selectedIndex];
            }
        } catch (e) { /* fall through */ }
        return null;
    }

    function wxpayClientName(client) {
        if (!client) return '';
        return client.clientName || client.ClientName || '';
    }

    function wxpayIsKioskLocked() {
        try {
            if (typeof isPressAnyKeyVisible === 'function') return isPressAnyKeyVisible();
        } catch (e) { /* fall through */ }
        var el = document.getElementById('pressAnyKeyScreen');
        return !!el && el.style.display !== 'none' && getComputedStyle(el).display !== 'none';
    }

    // ---------------------------------------------------------------------------
    // Floating entry button
    // ---------------------------------------------------------------------------
    function wxpayInjectButton() {
        if (document.getElementById('wxpayFloatBtn')) return;
        var btn = document.createElement('button');
        btn.id = 'wxpayFloatBtn';
        btn.type = 'button';
        btn.innerText = '微信扫码支付';
        Object.assign(btn.style, {
            position: 'fixed',
            right: '18px',
            bottom: '70px',
            zIndex: '9990',
            padding: '12px 20px',
            fontSize: '1.05rem',
            fontWeight: '700',
            color: '#fff',
            backgroundColor: '#07c160',
            border: 'none',
            borderRadius: '999px',
            boxShadow: '0 6px 20px rgba(0,0,0,0.45)',
            cursor: 'pointer'
        });
        btn.addEventListener('click', function () {
            if (wxpayIsKioskLocked()) return;
            wxpayShowAmountPicker();
        });
        document.body.appendChild(btn);
        wxpaySyncButtonVisibility();
        setInterval(wxpaySyncButtonVisibility, 1000);
    }

    function wxpaySyncButtonVisibility() {
        var btn = document.getElementById('wxpayFloatBtn');
        if (!btn) return;
        btn.style.display = wxpayIsKioskLocked() ? 'none' : 'block';
    }

    // ---------------------------------------------------------------------------
    // Amount picker modal
    // ---------------------------------------------------------------------------
    function wxpayEnsureModal(id) {
        var modal = document.getElementById(id);
        if (modal) return modal;
        modal = document.createElement('div');
        modal.id = id;
        modal.className = 'number-modal-overlay';
        Object.assign(modal.style, { zIndex: '10000' });
        modal.innerHTML = '<div class="number-modal-box" style="max-width: 440px;">' +
            '<div class="number-modal-pc-target" id="' + id + '-title">微信扫码支付</div>' +
            '<div id="' + id + '-body" style="margin-top: 12px;"></div>' +
            '</div>';
        document.body.appendChild(modal);
        return modal;
    }

    function wxpayShowModal(id) {
        var modal = wxpayEnsureModal(id);
        modal.classList.add('visible');
        modal.style.display = 'flex';
    }

    function wxpayHideModal(id) {
        var modal = document.getElementById(id);
        if (!modal) return;
        modal.classList.remove('visible');
        modal.style.display = 'none';
    }

    function wxpayFetchDuration(amountYuan) {
        var url = wxpayEndpoint('CalculateDurationFromAmountHandler.ashx') +
            '?amount=' + encodeURIComponent(amountYuan) +
            '&customerType=' + encodeURIComponent('GUEST / WALK-IN');
        return fetch(url, { cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (d) { return (d && d.totalMinutes) || 0; })
            .catch(function () { return 0; });
    }

    function wxpayShowAmountPicker() {
        var client = wxpaySelectedClient();
        var pcName = wxpayClientName(client);
        if (!pcName) {
            alert('请先选择一台电脑。');
            return;
        }
        var modal = wxpayEnsureModal('wxpayAmountModal');
        var title = document.getElementById('wxpayAmountModal-title');
        var body = document.getElementById('wxpayAmountModal-body');
        if (title) title.innerText = '微信扫码支付 · ' + pcName;
        if (body) body.innerHTML = '<div style="color:#cbd5e1;">正在加载价格…</div>';
        wxpayShowModal('wxpayAmountModal');

        Promise.all(wxpayQuickAmounts.map(function (amount) {
            return wxpayFetchDuration(amount).then(function (minutes) {
                return { amount: amount, minutes: minutes };
            });
        })).then(function (rows) {
            var html = '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">';
            rows.forEach(function (row) {
                var label = row.minutes > 0
                    ? ('¥' + row.amount + ' · ' + formatWxpayMinutes(row.minutes))
                    : ('¥' + row.amount + ' · 暂无时长');
                html += '<button type="button" data-wxpay-amount="' + row.amount + '" ' +
                    'style="padding:14px 8px;font-size:1.05rem;font-weight:700;color:#f8fafc;' +
                    'background:' + (row.minutes > 0 ? '#07c160' : '#475569') + ';border:none;border-radius:10px;cursor:pointer;"' +
                    (row.minutes <= 0 ? ' disabled' : '') + '>' + label + '</button>';
            });
            html += '</div>' +
                '<button type="button" id="wxpayAmountCancel" style="margin-top:14px;width:100%;padding:10px;' +
                'font-size:0.95rem;color:#cbd5e1;background:transparent;border:1px solid #475569;' +
                'border-radius:10px;cursor:pointer;">取消</button>';
            body.innerHTML = html;
            body.querySelectorAll('[data-wxpay-amount]').forEach(function (btn) {
                btn.addEventListener('click', function () {
                    var amount = parseFloat(btn.getAttribute('data-wxpay-amount'));
                    wxpayHideModal('wxpayAmountModal');
                    wxpayCreateOrder(pcName, amount);
                });
            });
            var cancel = document.getElementById('wxpayAmountCancel');
            if (cancel) cancel.addEventListener('click', function () { wxpayHideModal('wxpayAmountModal'); });
        });
    }

    function formatWxpayMinutes(totalMinutes) {
        if (totalMinutes <= 0) return '0分钟';
        var h = Math.floor(totalMinutes / 60);
        var m = totalMinutes % 60;
        if (h > 0 && m > 0) return h + '小时' + m + '分钟';
        if (h > 0) return h + '小时';
        return m + '分钟';
    }

    // ---------------------------------------------------------------------------
    // Create order -> QR modal -> poll -> unlock
    // ---------------------------------------------------------------------------
    function wxpayCreateOrder(pcName, amountYuan) {
        var modal = wxpayEnsureModal('wxpayQrModal');
        var title = document.getElementById('wxpayQrModal-title');
        var body = document.getElementById('wxpayQrModal-body');
        if (title) title.innerText = '微信扫码支付 · ' + pcName;
        if (body) body.innerHTML = '<div style="color:#cbd5e1;">正在生成付款码…</div>';
        wxpayShowModal('wxpayQrModal');

        var form = new URLSearchParams();
        form.append('computerName', pcName);
        form.append('amount', String(amountYuan));

        fetch(wxpayEndpoint('CreateWeChatPayOrderHandler.ashx'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: form.toString()
        })
        .then(function (r) { return r.json(); })
        .then(function (res) {
            if (!res || !res.success || !res.data || !res.data.codeUrl) {
                throw new Error((res && res.message) || '下单失败');
            }
            wxpayCurrentOrder = {
                outTradeNo: res.data.outTradeNo,
                computerName: pcName,
                amount: res.data.amount,
                durationMinutes: res.data.durationMinutes
            };
            wxpayShowQr(res.data.codeUrl, pcName, res.data.amount, res.data.durationMinutes);
            wxpayStartPolling();
        })
        .catch(function (err) {
            if (body) {
                body.innerHTML = '<div style="color:#ff3b30;">' + escapeWxpayHtml(err.message || '下单失败') + '</div>' +
                    '<button type="button" onclick="document.getElementById(\'wxpayQrModal\').classList.remove(\'visible\');document.getElementById(\'wxpayQrModal\').style.display=\'none\';" ' +
                    'style="margin-top:14px;width:100%;padding:10px;font-size:0.95rem;color:#cbd5e1;background:transparent;border:1px solid #475569;border-radius:10px;cursor:pointer;">关闭</button>';
            }
        });
    }

    function wxpayShowQr(codeUrl, pcName, amountYuan, durationMinutes) {
        var body = document.getElementById('wxpayQrModal-body');
        if (!body) return;
        var qrImg = 'https://api.qrserver.com/v1/create-qr-code/?size=240x240&margin=8&data=' + encodeURIComponent(codeUrl);
        wxpayRemainingSeconds = 300;
        body.innerHTML =
            '<div style="text-align:center;">' +
            '<img src="' + qrImg + '" alt="微信付款码" style="width:240px;height:240px;background:#fff;border-radius:8px;" />' +
            '<div style="margin-top:10px;font-size:1.2rem;font-weight:700;color:#f8fafc;">¥' + amountYuan + ' · ' + formatWxpayMinutes(durationMinutes) + '</div>' +
            '<div style="margin-top:4px;font-size:0.9rem;color:#cbd5e1;">打开微信扫一扫付款，' + pcName + ' 将自动解锁</div>' +
            '<div id="wxpayQrCountdown" style="margin-top:8px;font-size:0.9rem;color:#f59e0b;">付款码 5:00 后过期</div>' +
            '<div style="margin-top:6px;font-size:0.75rem;color:#64748b;word-break:break-all;">' + escapeWxpayHtml(codeUrl) + '</div>' +
            '<button type="button" id="wxpayQrCancel" style="margin-top:14px;width:100%;padding:10px;font-size:0.95rem;color:#cbd5e1;background:transparent;border:1px solid #475569;border-radius:10px;cursor:pointer;">取消支付</button>' +
            '</div>';
        var cancel = document.getElementById('wxpayQrCancel');
        if (cancel) cancel.addEventListener('click', wxpayStopAndClose);

        if (wxpayCountdownTimer) clearInterval(wxpayCountdownTimer);
        wxpayCountdownTimer = setInterval(function () {
            wxpayRemainingSeconds--;
            var el = document.getElementById('wxpayQrCountdown');
            if (el) {
                var mm = Math.floor(wxpayRemainingSeconds / 60);
                var ss = String(wxpayRemainingSeconds % 60).padStart(2, '0');
                el.innerText = '付款码 ' + mm + ':' + ss + ' 后过期';
            }
            if (wxpayRemainingSeconds <= 0) wxpayStopAndClose();
        }, 1000);
    }

    function wxpayStartPolling() {
        wxpayStopPolling();
        wxpayPollTimer = setInterval(function () {
            if (!wxpayCurrentOrder) { wxpayStopPolling(); return; }
            var url = wxpayEndpoint('QueryWeChatPayOrderHandler.ashx') +
                '?outTradeNo=' + encodeURIComponent(wxpayCurrentOrder.outTradeNo);
            fetch(url, { cache: 'no-store' })
                .then(function (r) { return r.json(); })
                .then(function (res) {
                    if (res && res.paid) wxpayOnPaid();
                })
                .catch(function () { /* transient network error: keep polling */ });
        }, 2500);
    }

    function wxpayStopPolling() {
        if (wxpayPollTimer) { clearInterval(wxpayPollTimer); wxpayPollTimer = null; }
    }

    function wxpayStopAndClose() {
        wxpayStopPolling();
        if (wxpayCountdownTimer) { clearInterval(wxpayCountdownTimer); wxpayCountdownTimer = null; }
        wxpayCurrentOrder = null;
        wxpayHideModal('wxpayQrModal');
    }

    function wxpayOnPaid() {
        var order = wxpayCurrentOrder;
        wxpayStopPolling();
        if (wxpayCountdownTimer) { clearInterval(wxpayCountdownTimer); wxpayCountdownTimer = null; }
        wxpayCurrentOrder = null;
        if (!order) return;

        var body = document.getElementById('wxpayQrModal-body');
        if (body) body.innerHTML = '<div style="text-align:center;color:#22c55e;font-size:1.2rem;font-weight:700;">支付成功，正在解锁 ' + escapeWxpayHtml(order.computerName) + '…</div>';

        // 1. Billing record (same endpoint the member login flow uses on the client).
        var form = new URLSearchParams();
        form.append('computerName', order.computerName);
        form.append('userId', 'Guest / Walk-in');
        form.append('duration', String(order.durationMinutes));
        form.append('amount', String(order.amount));
        var rentalPromise = fetch(wxpayEndpoint('CreateRentalHandler.ashx'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: form.toString()
        }).then(function (r) { return r.json(); }).catch(function () { return null; });

        rentalPromise.then(function () {
            // 2. Unlock the PC: same JSON session message the coin flow sends.
            // MainForm.HandleIncomingTextMessage parses it and calls UnlockScreen().
            var sent = false;
            try {
                if (typeof sendTextMessageToPC === 'function') {
                    sent = sendTextMessageToPC(order.computerName, JSON.stringify({
                        userId: 'Guest / Walk-in',
                        duration: String(order.durationMinutes),
                        amount: String(order.amount)
                    }));
                }
            } catch (e) { sent = false; }

            if (body) {
                body.innerHTML = sent
                    ? '<div style="text-align:center;color:#22c55e;font-size:1.2rem;font-weight:700;">支付成功！' + escapeWxpayHtml(order.computerName) + ' 已解锁</div>'
                    : '<div style="text-align:center;color:#f59e0b;font-size:1.1rem;font-weight:700;">已收款，但解锁指令没发出去（投币机与服务器的连接断了）。<br/>请联系网管手动开卡。</div>';
            }
            setTimeout(function () { wxpayHideModal('wxpayQrModal'); }, sent ? 2500 : 6000);
        });
    }

    function escapeWxpayHtml(str) {
        return str ? String(str).replace(/[&<>"']/g, function (s) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[s];
        }) : '';
    }

    // Expose for debugging / manual trigger from the console.
    window.startWeChatPay = function () { wxpayShowAmountPicker(); };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wxpayInjectButton);
    } else {
        wxpayInjectButton();
    }
})();
