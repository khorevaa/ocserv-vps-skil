(function () {
  "use strict";

  const state = {
    csrfToken: "",
    operator: null,
    users: [],
    connections: [],
    journal: [],
    usersLoaded: false,
    connectionsLoaded: false,
    journalLoaded: false,
    overviewLoaded: false,
    currentView: "overview",
    rotateUsername: "",
    disconnectID: 0,
    activeModal: null,
    lastFocused: null,
  };

  const el = (id) => document.getElementById(id);
  const bootView = el("boot-view");
  const appView = el("app-view");
  const logoutButton = el("logout-button");
  const sidebar = el("sidebar");
  const sidebarToggle = el("sidebar-toggle");
  const sidebarBackdrop = el("sidebar-backdrop");
  const modalBackdrop = el("modal-backdrop");
  const usersTableBody = el("users-table-body");
  const userSearch = el("user-search");
  const connectionsTableBody = el("connections-table-body");
  const journalTableBody = el("journal-table-body");

  const themeSelect = el("theme-select");
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");

  function applyTheme(mode) {
    const selected = ["system", "light", "dark"].includes(mode) ? mode : "system";
    if (selected === "system") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.dataset.theme = selected;
    themeSelect.value = selected;
    try { localStorage.setItem("ocserv-ui-theme", selected); } catch (_error) { /* preference remains in memory */ }
    const dark = selected === "dark" || (selected === "system" && systemTheme.matches);
    document.querySelector('meta[name="theme-color"]').setAttribute("content", dark ? "#101821" : "#f7f9fc");
  }

  let savedTheme = "system";
  try { savedTheme = localStorage.getItem("ocserv-ui-theme") || "system"; } catch (_error) { /* system default */ }
  applyTheme(savedTheme);
  themeSelect.addEventListener("change", () => applyTheme(themeSelect.value));
  systemTheme.addEventListener("change", () => {
    if (themeSelect.value === "system") applyTheme("system");
  });

  class ApiError extends Error {
    constructor(message, status, payload) {
      super(message);
      this.name = "ApiError";
      this.status = status;
      this.payload = payload;
    }
  }

  function normalizedErrorMessage(payload, fallback) {
    if (payload && typeof payload === "object") {
      const translated = {
        user_exists: "Пользователь с таким именем уже существует.",
        user_not_found: "Пользователь не найден.",
        operation_busy: "Сейчас выполняется другая операция. Повторите попытку позже.",
        control_unavailable: "Служба управления ocserv временно недоступна.",
        backend_unavailable: "Служба ocserv временно недоступна.",
        backend_error: "Служба ocserv отклонила операцию.",
        invalid_connection_id: "Подключение уже завершено или имеет некорректный идентификатор.",
      }[payload.error];
      if (translated) return translated;
      const value = payload.message || payload.error || payload.detail;
      if (typeof value === "string" && value.trim()) {
        return value.trim();
      }
      if (Array.isArray(value) && value.length) {
        return value
          .map((item) => (item && typeof item.msg === "string" ? item.msg : ""))
          .filter(Boolean)
          .join("; ") || fallback;
      }
    }
    return fallback;
  }

  async function apiRequest(path, options = {}) {
    const method = options.method || "GET";
    const headers = new Headers({ Accept: "application/json" });

    if (options.body !== undefined) {
      headers.set("Content-Type", "application/json");
    }
    if (options.csrf !== false && !["GET", "HEAD"].includes(method) && state.csrfToken) {
      headers.set("X-CSRF-Token", state.csrfToken);
    }

    let response;
    try {
      response = await fetch(path, {
        method,
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        credentials: "same-origin",
        cache: "no-store",
      });
    } catch (_error) {
      throw new ApiError("Не удалось связаться с сервером. Проверьте подключение и повторите попытку.", 0, null);
    }

    const contentType = response.headers.get("content-type") || "";
    let payload = null;
    if (contentType.includes("application/json")) {
      try {
        payload = await response.json();
      } catch (_error) {
        payload = null;
      }
    }

    if (!response.ok) {
      if (response.status === 404 && response.headers.get("x-ocserv-ui-access") === "required") {
        window.location.replace("/");
        throw new ApiError("Требуется повторно ввести секрет доступа.", 404, payload);
      }
      const fallback = response.status === 401
        ? "Сессия истекла. Войдите снова."
        : response.status === 429
          ? "Слишком много попыток. Подождите и повторите вход."
          : `Сервер вернул ошибку ${response.status}.`;
      throw new ApiError(normalizedErrorMessage(payload, fallback), response.status, payload);
    }

    return payload;
  }

  function setHidden(element, hidden) {
    element.classList.toggle("is-hidden", hidden);
  }

  function showInlineError(element, message) {
    element.textContent = message;
    setHidden(element, false);
  }

  function clearInlineError(element) {
    element.textContent = "";
    setHidden(element, true);
  }

  function setBusy(button, busy) {
    button.disabled = busy;
    button.setAttribute("aria-busy", String(busy));
  }

  function showToast(message, variant = "default") {
    const toast = document.createElement("div");
    toast.className = `toast${variant === "default" ? "" : ` toast--${variant}`}`;
    toast.textContent = message;
    el("toast-region").appendChild(toast);
    window.setTimeout(() => toast.remove(), 4200);
  }

  function clearSession() {
    state.csrfToken = "";
    state.operator = null;
    state.users = [];
    state.connections = [];
    state.journal = [];
    state.usersLoaded = false;
    state.connectionsLoaded = false;
    state.journalLoaded = false;
    state.overviewLoaded = false;
  }

  function applySession(payload) {
    if (!payload || !payload.user || typeof payload.user.username !== "string") {
      throw new ApiError("Сервер вернул некорректные данные сессии.", 0, payload);
    }
    if (typeof payload.csrf_token !== "string" || !payload.csrf_token) {
      throw new ApiError("Сервер не выдал CSRF-токен для защищённых операций.", 0, payload);
    }
    state.operator = payload.user;
    state.csrfToken = payload.csrf_token;
  }

  function showApp() {
    setHidden(bootView, true);
    setHidden(appView, false);
    const requestedView = window.location.hash.slice(1);
    navigateTo(["overview", "connections", "journal", "users"].includes(requestedView) ? requestedView : "overview");
  }

  function handleUnauthorized(error) {
    if (error instanceof ApiError && error.status === 401) {
      clearSession();
      window.location.replace("/");
      return true;
    }
    return false;
  }

  async function initialize() {
    try {
      const session = await apiRequest("/api/v1/auth/me");
      applySession(session);
      showApp();
    } catch (error) {
      clearSession();
      window.location.replace("/");
    }
  }

  logoutButton.addEventListener("click", async () => {
    setBusy(logoutButton, true);
    try {
      await apiRequest("/api/v1/auth/logout", { method: "POST" });
      clearSession();
      window.location.replace("/");
    } catch (error) {
      if (!handleUnauthorized(error)) {
        showToast(error.message || "Не удалось завершить сессию.", "danger");
      }
    } finally {
      setBusy(logoutButton, false);
    }
  });

  function navigateTo(view) {
    const nextView = ["overview", "connections", "journal", "users"].includes(view) ? view : "overview";
    state.currentView = nextView;
    document.querySelectorAll("[data-panel]").forEach((panel) => {
      setHidden(panel, panel.dataset.panel !== nextView);
    });
    document.querySelectorAll("[data-view]").forEach((link) => {
      const active = link.dataset.view === nextView;
      link.classList.toggle("is-active", active);
      if (active) {
        link.setAttribute("aria-current", "page");
      } else {
        link.removeAttribute("aria-current");
      }
    });
    const titles = { overview: "Состояние системы", connections: "Подключения", journal: "Журнал", users: "Пользователи" };
    document.title = `${titles[nextView]} — ocserv VPN Server`;
    closeSidebar();

    if (nextView === "users") loadUsers();
    else if (nextView === "connections") loadConnections();
    else if (nextView === "journal") loadJournal();
    else loadOverview();
  }

  document.querySelectorAll("[data-view]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const view = link.dataset.view;
      if (window.location.hash !== `#${view}`) {
        window.location.hash = view;
      } else {
        navigateTo(view);
      }
    });
  });

  window.addEventListener("hashchange", () => {
    if (!appView.classList.contains("is-hidden")) {
      navigateTo(window.location.hash.slice(1));
    }
  });

  function openSidebar() {
    sidebar.classList.add("is-open");
    sidebarBackdrop.classList.add("is-open");
    sidebarToggle.setAttribute("aria-expanded", "true");
  }

  function closeSidebar() {
    sidebar.classList.remove("is-open");
    sidebarBackdrop.classList.remove("is-open");
    sidebarToggle.setAttribute("aria-expanded", "false");
  }

  sidebarToggle.addEventListener("click", () => {
    if (sidebar.classList.contains("is-open")) {
      closeSidebar();
    } else {
      openSidebar();
    }
  });
  sidebarBackdrop.addEventListener("click", closeSidebar);

  function textOrDash(value) {
    if (value === null || value === undefined || value === "") {
      return "—";
    }
    return String(value);
  }

  function safeCount(value) {
    const number = Number(value);
    return Number.isFinite(number) && number >= 0 ? Math.floor(number) : 0;
  }

  function formatUptime(value) {
    const total = Number(value);
    if (!Number.isFinite(total) || total < 0) {
      return "—";
    }
    let seconds = Math.floor(total);
    const days = Math.floor(seconds / 86400);
    seconds %= 86400;
    const hours = Math.floor(seconds / 3600);
    seconds %= 3600;
    const minutes = Math.floor(seconds / 60);
    const parts = [];
    if (days) parts.push(`${days} д`);
    if (hours || days) parts.push(`${hours} ч`);
    parts.push(`${minutes} мин`);
    return parts.join(" ");
  }

  function formatDateTime(value) {
    if (!value) return "—";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return textOrDash(value);
    return new Intl.DateTimeFormat("ru-RU", {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  }

  function pluralize(number, forms) {
    const absolute = Math.abs(number) % 100;
    const last = absolute % 10;
    if (absolute > 10 && absolute < 20) return forms[2];
    if (last > 1 && last < 5) return forms[1];
    if (last === 1) return forms[0];
    return forms[2];
  }

  function isServiceOnline(status) {
    const normalized = String(status || "").toLowerCase();
    return ["online", "running", "healthy", "active", "up"].includes(normalized);
  }

  function renderOverview(data) {
    const service = data && typeof data.service === "object" ? data.service : {};
    const vpn = data && typeof data.vpn === "object" ? data.vpn : {};
    const certificate = data && typeof data.certificate === "object" ? data.certificate : {};
    const online = isServiceOnline(service.status);
    const statusBadge = el("service-status");
    const serviceIcon = el("service-icon");

    statusBadge.textContent = online ? "Включён" : "Недоступен";
    statusBadge.className = `status-badge ${online ? "status-badge--online" : "status-badge--offline"}`;
    serviceIcon.classList.toggle("is-online", online);
    serviceIcon.classList.toggle("is-offline", !online);

    el("service-domain").textContent = textOrDash(vpn.domain);
    el("active-connections").textContent = String(safeCount(vpn.active_connections));
    el("vpn-users").textContent = String(safeCount(vpn.users));
    el("service-version").textContent = textOrDash(service.version);
    el("service-image").textContent = textOrDash(service.image);
    el("service-uptime").textContent = formatUptime(service.uptime_seconds);
    el("vpn-port").textContent = textOrDash(vpn.port);
    el("vpn-network").textContent = textOrDash(vpn.network);
    el("certificate-expiry").textContent = formatDateTime(certificate.not_after);
    el("openconnect-check").textContent = formatDateTime(data ? data.last_openconnect_check : null);

    const rawDays = Number(certificate.days_remaining);
    const certificateState = el("certificate-state");
    certificateState.className = "status-dot-label";
    if (Number.isFinite(rawDays)) {
      const days = Math.floor(rawDays);
      el("certificate-days").textContent = days >= 0
        ? `${days} ${pluralize(days, ["день", "дня", "дней"])}`
        : "Срок истёк";
      if (days < 0) {
        certificateState.classList.add("is-danger");
        certificateState.querySelector("span").textContent = "Истёк";
      } else if (days < 7) {
        certificateState.classList.add("is-danger");
        certificateState.querySelector("span").textContent = "Требует обновления";
      } else if (days < 30) {
        certificateState.classList.add("is-warning");
        certificateState.querySelector("span").textContent = "Скоро истекает";
      } else {
        certificateState.classList.add("is-good");
        certificateState.querySelector("span").textContent = "Действителен";
      }
    } else {
      el("certificate-days").textContent = "—";
      certificateState.querySelector("span").textContent = "Нет данных";
    }
  }

  async function loadOverview(force = false) {
    if (state.overviewLoaded && !force) return;
    const refreshButton = el("overview-refresh");
    clearInlineError(el("overview-error"));
    setBusy(refreshButton, true);
    try {
      const data = await apiRequest("/api/v1/overview");
      renderOverview(data || {});
      state.overviewLoaded = true;
    } catch (error) {
      if (!handleUnauthorized(error)) {
        showInlineError(el("overview-error"), error.message || "Не удалось загрузить информацию о сервере.");
      }
    } finally {
      setBusy(refreshButton, false);
    }
  }

  el("overview-refresh").addEventListener("click", () => loadOverview(true));

  function normalizeUsers(payload) {
    if (!payload || !Array.isArray(payload.users)) return [];
    return payload.users
      .filter((user) => user && typeof user.username === "string" && user.username.trim())
      .map((user) => ({
        username: user.username,
        activeSessions: safeCount(user.active_sessions),
      }))
      .sort((left, right) => left.username.localeCompare(right.username, "ru", { sensitivity: "base" }));
  }

  function renderUsers() {
    const query = userSearch.value.trim().toLocaleLowerCase("ru");
    const visibleUsers = query
      ? state.users.filter((user) => user.username.toLocaleLowerCase("ru").includes(query))
      : state.users;

    usersTableBody.replaceChildren();
    const fragment = document.createDocumentFragment();
    visibleUsers.forEach((user) => {
      const row = document.createElement("tr");

      const usernameCell = document.createElement("td");
      usernameCell.className = "username-cell";
      usernameCell.textContent = user.username;

      const statusCell = document.createElement("td");
      const status = document.createElement("span");
      status.className = `session-state${user.activeSessions > 0 ? " is-active" : ""}`;
      const dot = document.createElement("i");
      dot.setAttribute("aria-hidden", "true");
      status.append(dot, document.createTextNode(user.activeSessions > 0 ? "Подключён" : "Не подключён"));
      statusCell.appendChild(status);

      const sessionsCell = document.createElement("td");
      sessionsCell.textContent = String(user.activeSessions);

      const actionsCell = document.createElement("td");
      actionsCell.className = "table-action-cell";
      const rotateButton = document.createElement("button");
      rotateButton.type = "button";
      rotateButton.className = "button row-action";
      rotateButton.dataset.action = "rotate-password";
      rotateButton.dataset.username = user.username;
      rotateButton.setAttribute("aria-label", `Изменить пароль пользователя ${user.username}`);
      rotateButton.textContent = "Изменить пароль";
      actionsCell.appendChild(rotateButton);

      row.append(usernameCell, statusCell, sessionsCell, actionsCell);
      fragment.appendChild(row);
    });
    usersTableBody.appendChild(fragment);

    setHidden(el("users-loading"), true);
    setHidden(el("users-empty"), visibleUsers.length > 0);
    const displayed = visibleUsers.length;
    const total = state.users.length;
    el("users-count").textContent = query
      ? `${displayed} из ${total}`
      : `${total} ${pluralize(total, ["пользователь", "пользователя", "пользователей"])}`;
  }

  async function loadUsers(force = false) {
    if (state.usersLoaded && !force) {
      renderUsers();
      return;
    }
    const refreshButton = el("users-refresh");
    clearInlineError(el("users-error"));
    setHidden(el("users-loading"), false);
    setHidden(el("users-empty"), true);
    setBusy(refreshButton, true);
    try {
      const data = await apiRequest("/api/v1/users");
      state.users = normalizeUsers(data);
      state.usersLoaded = true;
      renderUsers();
    } catch (error) {
      setHidden(el("users-loading"), true);
      if (!handleUnauthorized(error)) {
        showInlineError(el("users-error"), error.message || "Не удалось загрузить пользователей.");
      }
    } finally {
      setBusy(refreshButton, false);
    }
  }

  userSearch.addEventListener("input", () => {
    if (state.usersLoaded) renderUsers();
  });
  el("users-refresh").addEventListener("click", () => loadUsers(true));
  usersTableBody.addEventListener("click", (event) => {
    const button = event.target.closest("[data-action='rotate-password']");
    if (!button) return;
    openRotatePassword(button.dataset.username || "");
  });

  function normalizeConnections(payload) {
    if (!payload || !Array.isArray(payload.connections)) return [];
    return payload.connections.filter((item) => item && Number.isInteger(Number(item.id)) && Number(item.id) > 0)
      .map((item) => ({
        id: Number(item.id),
        username: textOrDash(item.username),
        clientIP: textOrDash(item.client_ip),
        vpnIP: textOrDash(item.vpn_ip),
        protocol: textOrDash(item.protocol),
        connectedAt: item.connected_at || null,
        duration: safeCount(item.duration_seconds),
      }));
  }

  function renderConnections() {
    connectionsTableBody.replaceChildren();
    const fragment = document.createDocumentFragment();
    state.connections.forEach((connection) => {
      const row = document.createElement("tr");
      const username = document.createElement("td");
      username.className = "username-cell";
      username.textContent = connection.username;
      const clientIP = document.createElement("td");
      clientIP.className = "code-value";
      clientIP.textContent = connection.clientIP;
      const vpnIP = document.createElement("td");
      vpnIP.className = "code-value";
      vpnIP.textContent = connection.vpnIP;
      const protocol = document.createElement("td");
      protocol.textContent = connection.protocol;
      const duration = document.createElement("td");
      duration.textContent = formatUptime(connection.duration);
      duration.title = connection.connectedAt ? `Подключён ${formatDateTime(connection.connectedAt)}` : "";
      const actions = document.createElement("td");
      actions.className = "table-action-cell";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "button row-action row-action--danger";
      button.dataset.action = "disconnect";
      button.dataset.connectionId = String(connection.id);
      button.textContent = "Отключить";
      button.setAttribute("aria-label", `Отключить пользователя ${connection.username}`);
      actions.appendChild(button);
      row.append(username, clientIP, vpnIP, protocol, duration, actions);
      fragment.appendChild(row);
    });
    connectionsTableBody.appendChild(fragment);
    setHidden(el("connections-loading"), true);
    setHidden(el("connections-empty"), state.connections.length !== 0);
    const count = state.connections.length;
    el("connections-count").textContent = `${count} ${pluralize(count, ["подключение", "подключения", "подключений"])}`;
  }

  async function loadConnections(force = false) {
    if (state.connectionsLoaded && !force) return;
    const refresh = el("connections-refresh");
    clearInlineError(el("connections-error"));
    setHidden(el("connections-loading"), false);
    setHidden(el("connections-empty"), true);
    setBusy(refresh, true);
    try {
      state.connections = normalizeConnections(await apiRequest("/api/v1/connections"));
      state.connectionsLoaded = true;
      renderConnections();
    } catch (error) {
      setHidden(el("connections-loading"), true);
      if (!handleUnauthorized(error)) showInlineError(el("connections-error"), error.message || "Не удалось загрузить подключения.");
    } finally {
      setBusy(refresh, false);
    }
  }

  el("connections-refresh").addEventListener("click", () => loadConnections(true));
  connectionsTableBody.addEventListener("click", (event) => {
    const button = event.target.closest("[data-action='disconnect']");
    if (!button) return;
    const id = Number(button.dataset.connectionId);
    const connection = state.connections.find((item) => item.id === id);
    if (!connection) return;
    state.disconnectID = id;
    el("disconnect-username").textContent = connection.username;
    clearInlineError(el("disconnect-error"));
    openModal("disconnect-modal");
  });

  function normalizeJournal(payload) {
    if (!payload || !Array.isArray(payload.events)) return [];
    return payload.events.filter((item) => item && ["connected", "disconnected"].includes(item.event))
      .map((item) => ({
        occurredAt: item.occurred_at,
        event: item.event,
        username: textOrDash(item.username),
        clientIP: textOrDash(item.client_ip),
        vpnIP: textOrDash(item.vpn_ip),
        duration: safeCount(item.duration_seconds),
        bytesIn: safeCount(item.bytes_in),
        bytesOut: safeCount(item.bytes_out),
      }));
  }

  function formatBytes(value) {
    const bytes = safeCount(value);
    if (bytes < 1000) return `${bytes} Б`;
    if (bytes < 1000000) return `${(bytes / 1000).toFixed(1)} КБ`;
    if (bytes < 1000000000) return `${(bytes / 1000000).toFixed(1)} МБ`;
    return `${(bytes / 1000000000).toFixed(1)} ГБ`;
  }

  function renderJournal() {
    const filter = el("journal-filter").value;
    const events = filter === "all" ? state.journal : state.journal.filter((item) => item.event === filter);
    journalTableBody.replaceChildren();
    const fragment = document.createDocumentFragment();
    events.forEach((item) => {
      const row = document.createElement("tr");
      const occurred = document.createElement("td");
      occurred.textContent = formatDateTime(item.occurredAt);
      const eventCell = document.createElement("td");
      const badge = document.createElement("span");
      badge.className = `event-badge event-badge--${item.event}`;
      badge.textContent = item.event === "connected" ? "Подключён" : "Отключён";
      eventCell.appendChild(badge);
      const username = document.createElement("td");
      username.className = "username-cell";
      username.textContent = item.username;
      const clientIP = document.createElement("td");
      clientIP.className = "code-value";
      clientIP.textContent = item.clientIP;
      const vpnIP = document.createElement("td");
      vpnIP.className = "code-value";
      vpnIP.textContent = item.vpnIP;
      const details = document.createElement("td");
      details.className = "journal-details";
      details.textContent = item.event === "connected"
        ? "—"
        : `${formatUptime(item.duration)} · ↓ ${formatBytes(item.bytesIn)} · ↑ ${formatBytes(item.bytesOut)}`;
      row.append(occurred, eventCell, username, clientIP, vpnIP, details);
      fragment.appendChild(row);
    });
    journalTableBody.appendChild(fragment);
    setHidden(el("journal-loading"), true);
    setHidden(el("journal-empty"), events.length !== 0);
    const count = events.length;
    el("journal-count").textContent = `${count} ${pluralize(count, ["событие", "события", "событий"])}`;
  }

  async function loadJournal(force = false) {
    if (state.journalLoaded && !force) return;
    const refresh = el("journal-refresh");
    clearInlineError(el("journal-error"));
    setHidden(el("journal-loading"), false);
    setHidden(el("journal-empty"), true);
    setBusy(refresh, true);
    try {
      state.journal = normalizeJournal(await apiRequest("/api/v1/journal"));
      state.journalLoaded = true;
      renderJournal();
    } catch (error) {
      setHidden(el("journal-loading"), true);
      if (!handleUnauthorized(error)) showInlineError(el("journal-error"), error.message || "Не удалось загрузить журнал VPN-сервера.");
    } finally {
      setBusy(refresh, false);
    }
  }

  el("journal-refresh").addEventListener("click", () => loadJournal(true));
  el("journal-filter").addEventListener("change", renderJournal);

  function openModal(modalId) {
    if (!state.activeModal) {
      state.lastFocused = document.activeElement;
    }
    document.querySelectorAll(".modal").forEach((modal) => setHidden(modal, modal.id !== modalId));
    state.activeModal = el(modalId);
    setHidden(modalBackdrop, false);
    document.body.classList.add("modal-open");
    const firstControl = state.activeModal.querySelector("input:not([readonly])")
      || state.activeModal.querySelector("button");
    window.setTimeout(() => firstControl && firstControl.focus(), 0);
  }

  function closeModal(force = false) {
    if (!state.activeModal) return;
    if (state.activeModal.id === "credential-modal" && !force) return;
    if (state.activeModal.id === "credential-modal") {
      el("credential-password").value = "";
      el("credential-username").textContent = "—";
    }
    document.querySelectorAll(".modal").forEach((modal) => setHidden(modal, true));
    setHidden(modalBackdrop, true);
    document.body.classList.remove("modal-open");
    const restoreFocus = state.lastFocused;
    state.activeModal = null;
    state.lastFocused = null;
    if (restoreFocus && typeof restoreFocus.focus === "function") {
      window.setTimeout(() => restoreFocus.focus(), 0);
    }
  }

  document.querySelectorAll(".modal-close").forEach((button) => {
    button.addEventListener("click", () => closeModal());
  });

  modalBackdrop.addEventListener("click", (event) => {
    if (event.target === modalBackdrop && state.activeModal && state.activeModal.id !== "credential-modal") {
      closeModal();
    }
  });

  el("disconnect-submit").addEventListener("click", async () => {
    const id = state.disconnectID;
    if (!id) return;
    const submit = el("disconnect-submit");
    clearInlineError(el("disconnect-error"));
    setBusy(submit, true);
    try {
      await apiRequest(`/api/v1/connections/${id}`, { method: "DELETE" });
      state.disconnectID = 0;
      closeModal();
      state.connectionsLoaded = false;
      state.overviewLoaded = false;
      state.usersLoaded = false;
      state.journalLoaded = false;
      showToast("VPN-подключение завершено", "success");
      await loadConnections(true);
    } catch (error) {
      if (!handleUnauthorized(error)) showInlineError(el("disconnect-error"), error.message || "Не удалось завершить подключение.");
    } finally {
      setBusy(submit, false);
    }
  });

  document.addEventListener("keydown", (event) => {
    if (!state.activeModal) return;
    if (event.key === "Escape") {
      if (state.activeModal.id === "credential-modal") {
        event.preventDefault();
        showToast("Сначала сохраните одноразовый пароль.");
      } else {
        closeModal();
      }
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = Array.from(state.activeModal.querySelectorAll(
      "button:not(:disabled), input:not(:disabled), [href], [tabindex]:not([tabindex='-1'])"
    )).filter((item) => item.offsetParent !== null);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  el("add-user-button").addEventListener("click", () => {
    el("create-user-form").reset();
    clearInlineError(el("create-user-error"));
    openModal("create-user-modal");
  });

  el("create-user-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    clearInlineError(el("create-user-error"));
    const username = el("new-username").value.trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$/.test(username)) {
      showInlineError(el("create-user-error"), "Начните имя с буквы или цифры; далее используйте до 64 латинских букв, цифр и символов . _ @ -");
      el("new-username").focus();
      return;
    }

    const submit = el("create-user-submit");
    setBusy(submit, true);
    try {
      const credential = await apiRequest("/api/v1/users", {
        method: "POST",
        body: { username },
      });
      showCredential(credential);
      state.usersLoaded = false;
      state.overviewLoaded = false;
      state.connectionsLoaded = false;
      state.journalLoaded = false;
    } catch (error) {
      if (!handleUnauthorized(error)) {
        showInlineError(el("create-user-error"), error.message || "Не удалось создать пользователя.");
      }
    } finally {
      setBusy(submit, false);
    }
  });

  function openRotatePassword(username) {
    if (!username) return;
    state.rotateUsername = username;
    el("rotate-username").textContent = username;
    el("terminate-sessions").checked = true;
    clearInlineError(el("rotate-password-error"));
    openModal("rotate-password-modal");
  }

  el("rotate-password-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const username = state.rotateUsername;
    if (!username) return;
    clearInlineError(el("rotate-password-error"));
    const submit = el("rotate-password-submit");
    setBusy(submit, true);
    try {
      const credential = await apiRequest(`/api/v1/users/${encodeURIComponent(username)}/password`, {
        method: "PUT",
        body: { terminate_sessions: el("terminate-sessions").checked },
      });
      showCredential(credential);
      state.usersLoaded = false;
      state.overviewLoaded = false;
      state.connectionsLoaded = false;
      state.journalLoaded = false;
    } catch (error) {
      if (!handleUnauthorized(error)) {
        showInlineError(el("rotate-password-error"), error.message || "Не удалось изменить пароль.");
      }
    } finally {
      setBusy(submit, false);
    }
  });

  function showCredential(credential) {
    if (!credential || typeof credential.username !== "string" || typeof credential.password !== "string") {
      throw new ApiError("Сервер не вернул новые учётные данные.", 0, credential);
    }
    el("credential-username").textContent = credential.username;
    el("credential-password").value = credential.password;
    openModal("credential-modal");
    if (credential.warning === "session_termination_failed") {
      showToast("Пароль изменён, но активные VPN-сессии завершить не удалось.", "danger");
    }
    window.setTimeout(() => el("credential-password").select(), 0);
  }

  async function copyPassword() {
    const output = el("credential-password");
    const password = output.value;
    if (!password) return;
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(password);
      } else {
        output.focus();
        output.select();
        if (!document.execCommand("copy")) {
          throw new Error("copy command failed");
        }
      }
      showToast("Пароль скопирован", "success");
    } catch (_error) {
      output.focus();
      output.select();
      showToast("Не удалось скопировать автоматически. Скопируйте выделенный пароль вручную.", "danger");
    }
  }

  el("copy-password-button").addEventListener("click", copyPassword);
  el("credential-close").addEventListener("click", () => {
    el("credential-password").value = "";
    el("credential-username").textContent = "—";
    closeModal(true);
    showToast("Учётные данные обновлены", "success");
    if (state.currentView === "users") {
      loadUsers(true);
    }
  });

  initialize();
})();
