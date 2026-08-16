import { Controller } from "@hotwired/stimulus";

const CAPTCHA_SCRIPT_URL = "https://captcha-api.yandex.ru/captcha.js";

export default class extends Controller {
  static targets = ["widget", "token", "submit", "error"];
  static values = {
    siteKey: String,
    errorMessage: String,
  };

  connect() {
    this.loadCaptcha()
      .then(() => this.renderCaptcha())
      .catch(() => this.showError());
  }

  disconnect() {
    if (this.widgetId && window.smartCaptcha) {
      window.smartCaptcha.destroy(this.widgetId);
    }
  }

  loadCaptcha() {
    if (window.smartCaptcha) return Promise.resolve();

    return new Promise((resolve, reject) => {
      let script = document.querySelector(`script[src="${CAPTCHA_SCRIPT_URL}"]`);

      if (!script) {
        script = document.createElement("script");
        script.src = CAPTCHA_SCRIPT_URL;
        script.async = true;
        script.dataset.lkdrCaptchaState = "loading";
        document.head.appendChild(script);
      }

      const timeoutId = window.setTimeout(() => reject(new Error("Captcha script timed out")), 10_000);
      script.addEventListener("load", () => {
        window.clearTimeout(timeoutId);
        resolve();
      }, { once: true });
      script.addEventListener("error", () => {
        window.clearTimeout(timeoutId);
        reject(new Error("Captcha script failed to load"));
      }, { once: true });

      if (window.smartCaptcha) {
        window.clearTimeout(timeoutId);
        resolve();
      }
    });
  }

  renderCaptcha() {
    this.widgetId = window.smartCaptcha.render(this.widgetTarget, {
      sitekey: this.siteKeyValue,
      callback: (token) => {
        this.tokenTarget.value = token;
        this.submitTarget.disabled = false;
      },
      "expired-callback": () => {
        this.tokenTarget.value = "";
        this.submitTarget.disabled = true;
      },
    });
  }

  showError() {
    this.errorTarget.textContent = this.errorMessageValue;
    this.errorTarget.classList.remove("hidden");
  }
}
