import { LightningElement, api, track } from "lwc";
import {
  createPortalTooltipBubble,
  destroyPortalTooltipBubble,
  positionTooltipBubble
} from "c/ers_datatableUtils";

export default class ErsTooltip extends LightningElement {
  @api message = "";
  /** When true, tooltip opens only on mouse hover (not focus). */
  @api hoverOnly = false;
  @track isVisible = false;
  _portalBubble = null;
  _boundReposition = null;
  _boundPortalMouseLeave = null;
  _hideTimer = null;

  connectedCallback() {
    this._boundReposition = this._repositionBubble.bind(this);
    this._boundPortalMouseLeave = this._handlePortalMouseLeave.bind(this);
  }

  disconnectedCallback() {
    this._clearHideTimer();
    this._teardownPortalBubble();
    this._detachListeners();
  }

  get hasMessage() {
    return !!(this.message && String(this.message).trim());
  }

  handleMouseEnter() {
    this._clearHideTimer();
    this.showTooltip();
  }

  handleMouseLeave() {
    this._scheduleHide();
  }

  handleFocusIn() {
    if (this.hoverOnly) return;
    this._clearHideTimer();
    this.showTooltip();
  }

  handleFocusOut() {
    if (this.hoverOnly) return;
    this.hideTooltip();
  }

  showTooltip() {
    if (!this.hasMessage) return;
    this.isVisible = true;
    if (!this._portalBubble) {
      this._portalBubble = createPortalTooltipBubble(this.message);
      this._portalBubble.addEventListener(
        "mouseleave",
        this._boundPortalMouseLeave
      );
      this._portalBubble.addEventListener("mouseenter", () => {
        this._clearHideTimer();
      });
    }
    window.addEventListener("scroll", this._boundReposition, true);
    window.addEventListener("resize", this._boundReposition);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    requestAnimationFrame(() => {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      requestAnimationFrame(() => this._repositionBubble());
    });
  }

  hideTooltip() {
    this._clearHideTimer();
    this.isVisible = false;
    this._teardownPortalBubble();
    this._detachListeners();
  }

  _scheduleHide() {
    this._clearHideTimer();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._hideTimer = setTimeout(() => {
      this._hideTimer = null;
      this.hideTooltip();
    }, 80);
  }

  _clearHideTimer() {
    if (this._hideTimer) {
      clearTimeout(this._hideTimer);
      this._hideTimer = null;
    }
  }

  _handlePortalMouseLeave() {
    this.hideTooltip();
  }

  _teardownPortalBubble() {
    if (this._portalBubble) {
      this._portalBubble.removeEventListener(
        "mouseleave",
        this._boundPortalMouseLeave
      );
    }
    destroyPortalTooltipBubble(this._portalBubble);
    this._portalBubble = null;
  }

  _detachListeners() {
    if (this._boundReposition) {
      window.removeEventListener("scroll", this._boundReposition, true);
      window.removeEventListener("resize", this._boundReposition);
    }
  }

  _getAnchorElement() {
    const root = this.template.querySelector(".ers-tooltip");
    if (!root) return null;
    const slot = root.querySelector("slot");
    if (slot && typeof slot.assignedElements === "function") {
      const assigned = slot.assignedElements();
      if (assigned.length > 0) {
        return assigned[0];
      }
    }
    return root;
  }

  _repositionBubble() {
    if (!this.isVisible || !this._portalBubble) return;
    const anchor = this._getAnchorElement();
    if (!anchor) return;
    positionTooltipBubble(anchor, this._portalBubble);
    this._portalBubble.classList.add("is-visible");
  }
}
