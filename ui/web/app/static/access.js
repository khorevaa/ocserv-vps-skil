(function () {
  "use strict";

  const form = document.getElementById("access-form");
  const input = document.getElementById("access-secret");
  const submit = document.getElementById("access-submit");
  const error = document.getElementById("access-error");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const secret = input.value.trim();
    error.classList.add("is-hidden");
    error.textContent = "";
    if (!/^[A-Za-z0-9_-]{43,256}$/.test(secret)) {
      error.textContent = "Проверьте секрет доступа.";
      error.classList.remove("is-hidden");
      input.select();
      return;
    }

    submit.disabled = true;
    try {
      const response = await fetch("/api/v1/access", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ secret }),
        credentials: "same-origin",
        cache: "no-store",
      });
      if (!response.ok) throw new Error("access denied");
      input.value = "";
      window.location.replace("/");
    } catch (_requestError) {
      input.value = "";
      error.textContent = "Доступ не подтверждён.";
      error.classList.remove("is-hidden");
      input.focus();
    } finally {
      submit.disabled = false;
    }
  });

  input.focus();
})();
