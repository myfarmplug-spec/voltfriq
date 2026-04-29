/* ─── VOLTFRIQ — REALTIME JOB CHAT ─────────────────────────────── */

const Chat = (() => {
  let currentJobId = null;
  let senderRole = null;
  let senderName = null;
  let container = null;
  let messageSubscription = null;

  async function init(containerId, jobId, nextSenderRole, nextSenderName) {
    currentJobId = jobId;
    senderRole = nextSenderRole;
    senderName = nextSenderName;
    container = document.getElementById(containerId);
    if (!container) return;

    container.innerHTML =
      '<div class="chat-messages" id="chat-messages-' + jobId + '"></div>' +
      '<div class="chat-input-bar">' +
        '<input type="text" class="chat-text-input" id="chat-input-' + jobId + '" placeholder="Type a message..." />' +
        '<button class="chat-send-btn" id="chat-send-' + jobId + '">' +
          '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M22 2L11 13"/><path d="M22 2L15 22L11 13L2 9L22 2Z"/></svg>' +
        '</button>' +
      '</div>';

    document.getElementById('chat-send-' + jobId).addEventListener('click', sendText);
    document.getElementById('chat-input-' + jobId).addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        sendText();
      }
    });

    await render();
    if (messageSubscription) messageSubscription.unsubscribe();
    messageSubscription = Store.subscribeToMessages(jobId, render);
  }

  async function sendText() {
    if (!currentJobId) return;
    const input = document.getElementById('chat-input-' + currentJobId);
    if (!input) return;
    const text = input.value.trim();
    if (!text) return;

    await Store.addJobMessage(currentJobId, senderRole, { text: text, sender_name: senderName }, 'text');
    input.value = '';
    await render();
  }

  async function sendSystemMessage(jobId, content) {
    await Store.addJobMessage(jobId, 'admin', { text: content, sender_name: 'VoltFriq' }, 'status');
    if (jobId === currentJobId) await render();
  }

  async function sendAssessment(jobId, sender, assessment) {
    await Store.addJobMessage(jobId, 'electrician', {
      findings: assessment.findings || '',
      measurements: assessment.measurements || '',
      sender_name: sender
    }, 'assessment');
    if (jobId === currentJobId) await render();
  }

  async function sendQuotation(jobId, sender, quotation) {
    await Store.addJobMessage(jobId, 'electrician', {
      items: quotation.items || [],
      total: quotation.total || 0,
      sender_name: sender
    }, 'quotation');
    if (jobId === currentJobId) await render();
  }

  async function sendReceipt(jobId, receipt) {
    await Store.addJobMessage(jobId, 'admin', receipt || {}, 'receipt');
    if (jobId === currentJobId) await render();
  }

  async function render() {
    if (!currentJobId || !container) return;
    const messagesEl = document.getElementById('chat-messages-' + currentJobId);
    if (!messagesEl) return;

    const messages = await Store.getJobMessages(currentJobId);
    messagesEl.innerHTML = messages.map((message) => renderMessage(message)).join('');
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function renderMessage(message) {
    const self = senderRole && message.sender_role === senderRole;
    const alignClass = message.message_type === 'status'
      ? 'chat-msg-system'
      : (self ? 'chat-msg-self' : 'chat-msg-other');
    const content = message.content || {};
    const displayName = content.sender_name || (message.sender && message.sender.full_name) || 'VoltFriq';
    const sentAt = timeAgo(new Date(message.created_at).getTime());

    if (message.message_type === 'status') {
      return '<div class="chat-msg chat-msg-system"><div class="chat-system-text">' + escapeHtml(content.text || '') + '</div></div>';
    }

    if (message.message_type === 'assessment') {
      return '<div class="chat-msg ' + alignClass + '">' +
        '<div class="chat-bubble chat-card-bubble">' +
          '<div class="chat-card-header">Assessment Report</div>' +
          '<div class="chat-card-body">' +
            '<div class="chat-card-row"><strong>Findings:</strong> ' + escapeHtml(content.findings || '') + '</div>' +
            (content.measurements ? '<div class="chat-card-row"><strong>Measurements:</strong> ' + escapeHtml(content.measurements) + '</div>' : '') +
          '</div>' +
          '<div class="chat-sender">' + escapeHtml(displayName) + ' · ' + sentAt + '</div>' +
        '</div>' +
      '</div>';
    }

    if (message.message_type === 'quotation') {
      const items = (content.items || []).map((item) => {
        return '<div class="chat-q-item"><span>' + escapeHtml(item.description || '') + '</span><span>' + Store.formatCurrency(item.lineTotal || item.amount || 0) + '</span></div>';
      }).join('');
      return '<div class="chat-msg ' + alignClass + '">' +
        '<div class="chat-bubble chat-card-bubble">' +
          '<div class="chat-card-header">Quotation</div>' +
          '<div class="chat-card-body">' +
            '<div class="chat-q-section"><div class="chat-q-label">Line items</div>' + items + '</div>' +
            '<div class="chat-q-total"><strong>Total:</strong> <strong>' + Store.formatCurrency(content.total || 0) + '</strong></div>' +
          '</div>' +
          '<div class="chat-sender">' + escapeHtml(displayName) + ' · ' + sentAt + '</div>' +
        '</div>' +
      '</div>';
    }

    if (message.message_type === 'receipt') {
      return '<div class="chat-msg chat-msg-system">' +
        '<div class="chat-bubble chat-card-bubble chat-receipt">' +
          '<div class="chat-card-header">Payment Receipt</div>' +
          '<div class="chat-card-body">' +
            '<div class="chat-card-row">Amount: ' + Store.formatCurrency(content.amount || 0) + '</div>' +
            '<div class="chat-card-row">Reference: ' + escapeHtml(content.reference || 'N/A') + '</div>' +
          '</div>' +
        '</div>' +
      '</div>';
    }

    return '<div class="chat-msg ' + alignClass + '">' +
      '<div class="chat-bubble">' +
        '<div class="chat-text">' + escapeHtml(content.text || '') + '</div>' +
        '<div class="chat-sender">' + escapeHtml(displayName) + ' · ' + sentAt + '</div>' +
      '</div>' +
    '</div>';
  }

  function escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function destroy() {
    if (messageSubscription) {
      messageSubscription.unsubscribe();
      messageSubscription = null;
    }
    currentJobId = null;
    senderRole = null;
    senderName = null;
    container = null;
  }

  return {
    init,
    render,
    sendText,
    sendSystemMessage,
    sendAssessment,
    sendQuotation,
    sendReceipt,
    destroy
  };
})();
