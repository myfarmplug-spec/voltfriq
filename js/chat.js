/* ─── VOLTFRIQ OCEAN — CHAT ENGINE ────────────────────────────────── */

const Chat = (() => {
  let _pollTimer = null;
  let _currentJobId = null;
  let _senderRole = null;
  let _senderName = null;
  let _container = null;
  let _lastCount = 0;

  function init(containerId, jobId, senderRole, senderName) {
    _currentJobId = jobId;
    _senderRole = senderRole;
    _senderName = senderName;
    _container = document.getElementById(containerId);
    if (!_container) return;

    _container.innerHTML = `
      <div class="chat-messages" id="chat-messages-${jobId}"></div>
      <div class="chat-input-bar">
        <input type="text" class="chat-text-input" id="chat-input-${jobId}" placeholder="Type a message…" />
        <button class="chat-send-btn" id="chat-send-${jobId}">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M22 2L11 13"/><path d="M22 2L15 22L11 13L2 9L22 2Z"/></svg>
        </button>
      </div>
    `;

    document.getElementById(`chat-send-${jobId}`).addEventListener('click', () => sendText());
    document.getElementById(`chat-input-${jobId}`).addEventListener('keydown', (e) => {
      if (e.key === 'Enter') sendText();
    });

    render();
    startPoll();
  }

  function sendText() {
    const input = document.getElementById(`chat-input-${_currentJobId}`);
    if (!input) return;
    const text = input.value.trim();
    if (!text) return;
    Store.addChatMessage(_currentJobId, {
      sender: _senderRole,
      senderName: _senderName,
      type: 'text',
      content: text
    });
    input.value = '';
    render();
  }

  function sendSystemMessage(jobId, content) {
    Store.addChatMessage(jobId, {
      sender: 'system',
      senderName: 'System',
      type: 'status',
      content: content
    });
    if (_currentJobId === jobId) render();
  }

  function sendAssessment(jobId, senderName, assessment) {
    Store.addChatMessage(jobId, {
      sender: 'electrician',
      senderName: senderName,
      type: 'assessment',
      content: assessment
    });
    if (_currentJobId === jobId) render();
  }

  function sendQuotation(jobId, senderName, quotation) {
    Store.addChatMessage(jobId, {
      sender: 'electrician',
      senderName: senderName,
      type: 'quotation',
      content: quotation
    });
    if (_currentJobId === jobId) render();
  }

  function sendReceipt(jobId, receipt) {
    Store.addChatMessage(jobId, {
      sender: 'system',
      senderName: 'System',
      type: 'receipt',
      content: receipt
    });
    if (_currentJobId === jobId) render();
  }

  function render() {
    if (!_currentJobId || !_container) return;
    const messagesEl = document.getElementById(`chat-messages-${_currentJobId}`);
    if (!messagesEl) return;

    const messages = Store.getChat(_currentJobId);
    _lastCount = messages.length;

    messagesEl.innerHTML = messages.map(msg => {
      const isSelf = msg.sender === _senderRole;
      const alignClass = msg.sender === 'system' ? 'chat-msg-system' : (isSelf ? 'chat-msg-self' : 'chat-msg-other');

      if (msg.type === 'status') {
        return `<div class="chat-msg chat-msg-system"><div class="chat-system-text">${msg.content}</div></div>`;
      }

      if (msg.type === 'assessment') {
        const a = msg.content;
        return `
          <div class="chat-msg ${alignClass}">
            <div class="chat-bubble chat-card-bubble">
              <div class="chat-card-header">📋 Assessment Report</div>
              <div class="chat-card-body">
                <div class="chat-card-row"><strong>Findings:</strong> ${a.findings}</div>
                ${a.measurements ? `<div class="chat-card-row"><strong>Measurements:</strong> ${a.measurements}</div>` : ''}
              </div>
              <div class="chat-sender">${msg.senderName} · ${timeAgo(msg.timestamp)}</div>
            </div>
          </div>`;
      }

      if (msg.type === 'quotation') {
        const q = msg.content;
        const items = (q.items || []).map(i => `<div class="chat-q-item"><span>${i.description}</span><span>${fmt(i.amount)}</span></div>`).join('');
        const materials = (q.materials || []).map(m => `<div class="chat-q-item"><span>${m.name} (x${m.quantity})</span><span>${fmt(m.unitPrice * m.quantity)}</span></div>`).join('');
        return `
          <div class="chat-msg ${alignClass}">
            <div class="chat-bubble chat-card-bubble">
              <div class="chat-card-header">💰 Quotation</div>
              <div class="chat-card-body">
                ${items ? `<div class="chat-q-section"><div class="chat-q-label">Labour</div>${items}</div>` : ''}
                ${materials ? `<div class="chat-q-section"><div class="chat-q-label">Materials <span class="chat-q-note">(supplied by VoltFriq)</span></div>${materials}</div>` : ''}
                <div class="chat-q-total"><strong>Total:</strong> <strong>${fmt(q.total)}</strong></div>
              </div>
              <div class="chat-sender">${msg.senderName} · ${timeAgo(msg.timestamp)}</div>
            </div>
          </div>`;
      }

      if (msg.type === 'receipt') {
        const r = msg.content;
        return `
          <div class="chat-msg chat-msg-system">
            <div class="chat-bubble chat-card-bubble chat-receipt">
              <div class="chat-card-header">✅ Payment Receipt</div>
              <div class="chat-card-body">
                <div class="chat-card-row">Amount: ${fmt(r.amount)}</div>
                <div class="chat-card-row">Reference: ${r.reference || 'N/A'}</div>
                <div class="chat-card-row">Date: ${fmtDate(r.date)}</div>
              </div>
            </div>
          </div>`;
      }

      // Text message
      return `
        <div class="chat-msg ${alignClass}">
          <div class="chat-bubble">
            <div class="chat-text">${msg.content}</div>
            <div class="chat-sender">${msg.senderName} · ${timeAgo(msg.timestamp)}</div>
          </div>
        </div>`;
    }).join('');

    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function startPoll() {
    stopPoll();
    _pollTimer = setInterval(() => {
      if (!_currentJobId) return;
      const messages = Store.getChat(_currentJobId);
      if (messages.length !== _lastCount) render();
    }, 2000);
  }

  function stopPoll() {
    if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
  }

  function destroy() {
    stopPoll();
    _currentJobId = null;
    _container = null;
  }

  return { init, render, sendText, sendSystemMessage, sendAssessment, sendQuotation, sendReceipt, destroy };
})();
