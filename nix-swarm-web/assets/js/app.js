import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const themeStorageKey = "phx:theme";
const validThemes = ["system", "light", "dark"];
// The zoom label reads 100% at `scale === 1`. The base scale converts that
// label into rendered units: it is the previous 0.3 multiplied by 4.3 so the
// default 100% view renders the topology 4.3x larger than before.
const mapBaseScale = 1.29;
const mapMinScale = 0.35;
const mapMaxScale = 4.5;
const sidebarWidthStorageKey = "nix-swarm:sidebar-width";
const sidebarVisibilityStorageKey = "nix-swarm:sidebar-visibility";
const sidebarWidthDefaults = { left: 320, right: 320 };
const sidebarViewportWidth = () => window.innerWidth > 600
  ? Math.floor(window.innerWidth / 2) - 32
  : window.innerWidth - 32;
const sidebarWidthLimits = (side) => ({
  min: side === "left" ? 240 : 260,
  max: Math.max(side === "left" ? 240 : 260, Math.min(780, sidebarViewportWidth())),
});
const systemTheme = () =>
  window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
const storedTheme = () => window.localStorage.getItem(themeStorageKey) || "system";

const applyTheme = (preference) => {
  const theme = preference === "system" ? systemTheme() : preference;
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.themeSource = preference;

  document.querySelectorAll("[data-theme-select]").forEach((select) => {
    select.value = preference;
  });
};

const savedTheme = storedTheme();
const initialTheme = validThemes.includes(savedTheme) ? savedTheme : "system";
applyTheme(initialTheme);
const synchronizeTheme = () => {
  const preference = storedTheme();
  applyTheme(validThemes.includes(preference) ? preference : "system");
};
window.addEventListener("DOMContentLoaded", synchronizeTheme);
window.addEventListener("phx:page-loading-stop", synchronizeTheme);

// LiveView may replace the shell during the initial connection or a live
// navigation. Keep the native select in sync without placing scripts in HEEx.
new MutationObserver(() => {
  synchronizeTheme();
  applySidebarWidths();
}).observe(document.body, {
  childList: true,
  subtree: true,
});

document.addEventListener("change", (event) => {
  const select = event.target.closest("[data-theme-select]");
  if (!select) return;

  const preference = select.value;
  if (preference === "system") {
    window.localStorage.removeItem(themeStorageKey);
  } else {
    window.localStorage.setItem(themeStorageKey, preference);
  }
  applyTheme(preference);
});

window.addEventListener("storage", (event) => {
  if (event.key === themeStorageKey) {
    applyTheme(event.newValue || "system");
  }
});

window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (document.documentElement.dataset.themeSource === "system") applyTheme("system");
});

const readSidebarWidth = (side) => {
  const limits = sidebarWidthLimits(side);
  const stored = Number.parseInt(window.localStorage.getItem(`${sidebarWidthStorageKey}:${side}`), 10);
  return Number.isFinite(stored)
    ? Math.min(limits.max, Math.max(limits.min, stored))
    : Math.min(limits.max, Math.max(limits.min, sidebarWidthDefaults[side]));
};

const applySidebarWidth = (sidebar) => {
  const side = sidebar?.dataset.mapSidebarSide;
  if (!sidebar || !(side in sidebarWidthDefaults)) return;
  const width = readSidebarWidth(side);
  sidebar.style.setProperty("--map-sidebar-width", `${width}px`);
  sidebar.dataset.sidebarWidth = String(width);
  sidebar.querySelector("[data-sidebar-resize]")?.setAttribute("aria-valuenow", String(width));
};

const applySidebarWidths = () => {
  document.querySelectorAll("[data-map-sidebar-side]").forEach(applySidebarWidth);
};

const applySidebarVisibility = (sidebar) => {
  const side = sidebar?.dataset.mapSidebarSide;
  if (!sidebar || !(side in sidebarWidthDefaults)) return;

  const collapsed = window.localStorage.getItem(`${sidebarVisibilityStorageKey}:${side}`) === "collapsed";
  sidebar.classList.toggle("is-collapsed", collapsed);
  const toggle = sidebar.querySelector("[data-map-sidebar-toggle]");
  toggle?.setAttribute("aria-expanded", String(!collapsed));
  if (toggle) toggle.textContent = collapsed ? "Show" : "Hide";
};

const MapSidebar = {
  mounted() {
    applySidebarWidth(this.el);
    applySidebarVisibility(this.el);
  },

  updated() {
    applySidebarWidth(this.el);
    applySidebarVisibility(this.el);
  },
};

window.addEventListener("DOMContentLoaded", () => {
  applySidebarWidths();
  document.querySelectorAll("[data-map-sidebar-side]").forEach(applySidebarVisibility);
});
window.addEventListener("phx:page-loading-stop", () => {
  applySidebarWidths();
  document.querySelectorAll("[data-map-sidebar-side]").forEach(applySidebarVisibility);
});

document.addEventListener("click", (event) => {
  const toggle = event.target.closest("[data-map-sidebar-toggle]");
  if (!toggle) return;

  const sidebar = toggle.closest("[data-map-sidebar]");
  if (!sidebar) return;

  const collapsed = sidebar.classList.toggle("is-collapsed");
  const side = sidebar.dataset.mapSidebarSide;
  window.localStorage.setItem(
    `${sidebarVisibilityStorageKey}:${side}`,
    collapsed ? "collapsed" : "expanded",
  );
  toggle.setAttribute("aria-expanded", String(!collapsed));
  toggle.textContent = collapsed ? "Show" : "Hide";
  window.dispatchEvent(new Event("nix-swarm-map-sidebar-toggle"));
});

let sidebarResize = null;

const setSidebarWidth = (sidebar, side, width) => {
  const limits = sidebarWidthLimits(side);
  const nextWidth = Math.min(limits.max, Math.max(limits.min, width));
  sidebar.style.setProperty("--map-sidebar-width", `${nextWidth}px`);
  sidebar.dataset.sidebarWidth = String(nextWidth);
  window.localStorage.setItem(`${sidebarWidthStorageKey}:${side}`, String(nextWidth));
  sidebar.querySelector("[data-sidebar-resize]")?.setAttribute("aria-valuenow", String(nextWidth));
};

document.addEventListener("pointerdown", (event) => {
  const handle = event.target.closest("[data-sidebar-resize]");
  const sidebar = handle?.closest("[data-map-sidebar-side]");
  if (!handle || !sidebar || sidebar.classList.contains("is-collapsed")) return;

  const side = sidebar.dataset.mapSidebarSide;
  if (!(side in sidebarWidthDefaults)) return;

  sidebarResize = {
    handle,
    sidebar,
    side,
    startX: event.clientX,
    startWidth: Number(sidebar.dataset.sidebarWidth) || sidebar.getBoundingClientRect().width,
  };
  handle.classList.add("is-resizing");
  try {
    handle.setPointerCapture?.(event.pointerId);
  } catch (_error) {
    // Synthetic events and some touch browsers do not expose capture.
  }
  event.preventDefault();
});

document.addEventListener("pointermove", (event) => {
  if (!sidebarResize) return;
  const delta = event.clientX - sidebarResize.startX;
  const width = sidebarResize.side === "left"
    ? sidebarResize.startWidth + delta
    : sidebarResize.startWidth - delta;
  setSidebarWidth(sidebarResize.sidebar, sidebarResize.side, width);
  window.dispatchEvent(new Event("nix-swarm-map-sidebar-resize"));
});

const finishSidebarResize = (event) => {
  if (!sidebarResize) return;
  sidebarResize.handle.classList.remove("is-resizing");
  try {
    sidebarResize.handle.releasePointerCapture?.(event.pointerId);
  } catch (_error) {
    // The pointer may already have been released by the browser.
  }
  sidebarResize = null;
};

document.addEventListener("pointerup", finishSidebarResize);
document.addEventListener("pointercancel", finishSidebarResize);

document.addEventListener("keydown", (event) => {
  const handle = event.target.closest("[data-sidebar-resize]");
  const sidebar = handle?.closest("[data-map-sidebar-side]");
  if (!handle || !sidebar || sidebar.classList.contains("is-collapsed")) return;

  const side = sidebar.dataset.mapSidebarSide;
  if (!(side in sidebarWidthDefaults) || !["ArrowLeft", "ArrowRight"].includes(event.key)) return;
  const increases = side === "left" ? event.key === "ArrowRight" : event.key === "ArrowLeft";
  const width = Number(sidebar.dataset.sidebarWidth) || sidebar.getBoundingClientRect().width;
  setSidebarWidth(sidebar, side, width + (increases ? 16 : -16));
  window.dispatchEvent(new Event("nix-swarm-map-sidebar-resize"));
  event.preventDefault();
});

document.addEventListener("click", async (event) => {
  const copyButton = event.target.closest("[data-copy-target]");
  if (!copyButton) return;

  const target = document.getElementById(copyButton.dataset.copyTarget);
  if (!target) return;

  const text = target.value || target.textContent;
  let copied = false;

  try {
    if (!navigator.clipboard?.writeText) throw new Error("clipboard unavailable");
    await navigator.clipboard.writeText(text);
    copied = true;
  } catch (_error) {
    target.focus();
    target.select();
    copied = document.execCommand("copy");
    target.setSelectionRange(0, 0);
    target.blur();
  }

  const originalLabel = copyButton.dataset.copyOriginalLabel || copyButton.textContent;
  copyButton.dataset.copyOriginalLabel = originalLabel;
  copyButton.textContent = copied ? "Copied" : "Copy failed";
  window.setTimeout(() => {
    copyButton.textContent = originalLabel;
  }, 1800);
});

const NetworkMap = {
  mounted() {
    this.svg = this.el.querySelector("[data-map-svg]");
    this.viewport = this.el.querySelector("[data-map-viewport]");
    this.positions = new Map();
    this.scale = 1;
    this.pan = { x: 0, y: 0 };
    this.pointer = null;
    this.selected = null;
    // Sidebar visibility is an overlay change; do not treat it as a Fit action.
    // Re-fitting here makes the map jump to a much larger logical zoom when the
    // sidebar disappears.
    this.sidebarToggleHandler = () => this.applyTransform();
    this.sidebarResizeHandler = () => this.applyTransform();

    this.el.addEventListener("click", (event) => {
      const action = event.target.closest("[data-map-action]");
      if (action) {
        this.handleAction(action.dataset.mapAction);
        return;
      }

      const item = event.target.closest("[data-map-item-kind]");
      if (item) this.selectItem(item);
    });

    this.el.addEventListener("keydown", (event) => {
      const item = event.target.closest("[data-map-item-kind]");
      if (item && (event.key === "Enter" || event.key === " ")) {
        event.preventDefault();
        this.selectItem(item);
        this.notifySelection(item);
      } else if (item && event.key === "Escape") {
        this.clearSelection();
      }
    });

    this.svg.addEventListener("pointerdown", (event) => this.startPointer(event));
    this.svg.addEventListener("pointermove", (event) => this.movePointer(event));
    this.svg.addEventListener("pointerup", (event) => this.endPointer(event));
    this.svg.addEventListener("pointercancel", (event) => this.endPointer(event));
    this.svg.addEventListener("wheel", (event) => {
      event.preventDefault();
      this.zoomAt(event.deltaY < 0 ? 1.12 : 0.89, event.clientX, event.clientY);
    }, { passive: false });
    window.addEventListener("nix-swarm-map-sidebar-toggle", this.sidebarToggleHandler);
    window.addEventListener("nix-swarm-map-sidebar-resize", this.sidebarResizeHandler);

    this.syncItems();
    this.setDefaultView();
  },

  destroyed() {
    window.removeEventListener("nix-swarm-map-sidebar-toggle", this.sidebarToggleHandler);
    window.removeEventListener("nix-swarm-map-sidebar-resize", this.sidebarResizeHandler);
  },

  updated() {
    this.syncItems();
    this.applyTransform();

    if (this.selected) {
      const item = this.findItem(this.selected.kind, this.selected.key);
      if (item) this.selectItem(item, false);
    }
  },

  syncItems() {
    this.items = [...this.el.querySelectorAll("[data-map-item-kind]")];
    this.machines = this.items.filter((item) => item.dataset.mapItemKind === "node");

    this.machines.forEach((machine) => {
      const key = this.itemKey(machine);
      if (!this.positions.has(key)) {
        this.positions.set(key, {
          x: Number(machine.dataset.mapX),
          y: Number(machine.dataset.mapY),
        });
      }
    });

    this.machines.forEach((machine) => {
      const key = this.itemKey(machine);
      this.positions.set(key, this.resolveMachinePosition(machine, this.positions.get(key)));
    });
    this.updateFlowEdges();
  },

  itemKey(item) {
    return `${item.dataset.mapItemKind}:${item.dataset.mapItemKey}`;
  },

  findItem(kind, key) {
    return this.items.find((item) =>
      item.dataset.mapItemKind === kind && item.dataset.mapItemKey === key
    );
  },

  machineBox(machine, position) {
    return {
      x: position.x,
      y: position.y,
      width: Number(machine.dataset.mapBoxWidth) || 0,
      height: Number(machine.dataset.mapBoxHeight) || 0,
    };
  },

  machineObstacles(machine) {
    const machines = this.machines
      .filter((candidate) => candidate !== machine)
      .map((candidate) => this.machineBox(candidate, this.positions.get(this.itemKey(candidate))))
      .filter((box) => box.width > 0 && box.height > 0);
    const unplaced = this.el.querySelector("[data-map-unplaced] > .map-unplaced-card");

    if (unplaced) {
      machines.push({
        x: Number(unplaced.getAttribute("x")) || 0,
        y: Number(unplaced.getAttribute("y")) || 0,
        width: Number(unplaced.getAttribute("width")) || 0,
        height: Number(unplaced.getAttribute("height")) || 0,
      });
    }

    const proxy = this.el.querySelector('[data-map-item-kind="proxy"]');
    if (proxy) {
      machines.push({
        x: Number(proxy.dataset.mapX) || 0,
        y: Number(proxy.dataset.mapY) || 0,
        width: Number(proxy.dataset.mapBoxWidth) || 0,
        height: Number(proxy.dataset.mapBoxHeight) || 0,
      });
    }

    return machines;
  },

  machineOverlaps(left, right, gap = 12) {
    return left.x < right.x + right.width + gap &&
      left.x + left.width + gap > right.x &&
      left.y < right.y + right.height + gap &&
      left.y + left.height + gap > right.y;
  },

  clampMachinePosition(machine, position) {
    const width = Number(this.el.dataset.mapWidth);
    const height = Number(this.el.dataset.mapHeight);
    const box = this.machineBox(machine, position);
    return {
      x: Math.min(Math.max(0, position.x), Math.max(0, width - box.width)),
      y: Math.min(Math.max(0, position.y), Math.max(0, height - box.height)),
    };
  },

  resolveMachinePosition(machine, requested, fallback = requested) {
    if (!requested) return requested;
    const obstacles = this.machineObstacles(machine);
    const box = this.machineBox(machine, requested);
    const candidate = this.clampMachinePosition(machine, requested);
    if (!obstacles.some((other) => this.machineOverlaps(this.machineBox(machine, candidate), other))) {
      return candidate;
    }

    const width = Number(this.el.dataset.mapWidth);
    const height = Number(this.el.dataset.mapHeight);
    const current = this.positions.get(this.itemKey(machine)) || fallback;
    const gap = 12;
    const xOptions = new Set([0, Math.max(0, width - box.width), candidate.x, current.x]);
    const yOptions = new Set([0, Math.max(0, height - box.height), candidate.y, current.y]);

    obstacles.forEach((obstacle) => {
      xOptions.add(obstacle.x - box.width - gap);
      xOptions.add(obstacle.x + obstacle.width + gap);
      yOptions.add(obstacle.y - box.height - gap);
      yOptions.add(obstacle.y + obstacle.height + gap);
    });

    const legal = [...xOptions]
      .flatMap((x) => [...yOptions].map((y) => this.clampMachinePosition(machine, { x, y })))
      .filter((option, index, options) =>
        options.findIndex((other) => other.x === option.x && other.y === option.y) === index
      )
      .filter((option) => {
        const optionBox = this.machineBox(machine, option);
        return !obstacles.some((other) => this.machineOverlaps(optionBox, other));
      })
      .sort((left, right) =>
        Math.hypot(left.x - requested.x, left.y - requested.y) -
        Math.hypot(right.x - requested.x, right.y - requested.y)
      );

    return legal[0] || this.clampMachinePosition(machine, fallback);
  },

  notifySelection(item) {
    if (this.pushEvent && item.dataset.mapItemKind !== "proxy") {
      this.pushEvent("map_item_selected", {
        kind: item.dataset.mapItemKind,
        key: item.dataset.mapTitle,
      });
    }
  },

  startPointer(event) {
    const item = event.target.closest("[data-map-item-kind]");
    const machine = item?.closest('[data-map-item-kind="node"]');
    const point = this.viewPoint(event.clientX, event.clientY);

    if (item && !machine) {
      // A standalone item (e.g. an unplaced service) selects but does not drag.
      this.selectItem(item);
      this.notifySelection(item);
      return;
    }

    if (machine) {
      const position = this.positions.get(this.itemKey(machine));
      this.pointer = {
        type: "item",
        item: machine,
        start: point,
        origin: { ...position },
        requested: { ...position },
        moved: false,
      };
      if (item) {
        this.selectItem(item);
        this.notifySelection(item);
      }
    } else {
      this.pointer = {
        type: "canvas",
        start: point,
        origin: { ...this.pan },
        moved: false,
      };
    }

    try {
      this.svg.setPointerCapture?.(event.pointerId);
    } catch (_error) {
      // Synthetic events and some touch browsers do not expose capture.
    }
    this.svg.classList.add("is-panning");
  },

  movePointer(event) {
    if (!this.pointer) return;

    const point = this.viewPoint(event.clientX, event.clientY);
    const dx = point.x - this.pointer.start.x;
    const dy = point.y - this.pointer.start.y;
    this.pointer.moved = this.pointer.moved || Math.abs(dx) + Math.abs(dy) > 2;

    if (this.pointer.type === "item") {
      const requested = {
        x: this.pointer.origin.x + dx / this.renderScale(),
        y: this.pointer.origin.y + dy / this.renderScale(),
      };
      const position = this.clampMachinePosition(this.pointer.item, requested);
      this.pointer.requested = position;
      this.positions.set(this.itemKey(this.pointer.item), position);
      this.pointer.item.classList.add("is-dragging");
      this.applyItemPosition(this.pointer.item, position);
    } else {
      this.pan = {
        x: this.pointer.origin.x + dx,
        y: this.pointer.origin.y + dy,
      };
      this.applyTransform();
    }
  },

  endPointer(event) {
    if (!this.pointer) return;
    if (this.pointer.type === "item" && this.pointer.moved) {
      const position = this.resolveMachinePosition(
        this.pointer.item,
        this.pointer.requested,
        this.pointer.origin,
      );
      this.positions.set(this.itemKey(this.pointer.item), position);
      this.applyItemPosition(this.pointer.item, position);
    }
    this.pointer.item?.classList.remove("is-dragging");
    try {
      this.svg.releasePointerCapture?.(event.pointerId);
    } catch (_error) {
      // The pointer may already have been released by the browser.
    }
    this.svg.classList.remove("is-panning");
    this.pointer = null;
  },

  handleAction(action) {
    if (action === "zoom-in") this.zoomAt(1.2);
    if (action === "zoom-out") this.zoomAt(0.83);
    if (action === "fit") this.fitToContent();
    if (action === "reset") this.resetLayout();
  },

  zoomAt(factor, clientX, clientY) {
    const nextScale = Math.min(mapMaxScale, Math.max(mapMinScale, this.scale * factor));
    if (nextScale === this.scale) return;

    const anchor = clientX === undefined
      ? { x: Number(this.el.dataset.mapWidth) / 2, y: Number(this.el.dataset.mapHeight) / 2 }
      : this.viewPoint(clientX, clientY);
    const contentPoint = {
      x: (anchor.x - this.pan.x) / this.renderScale(),
      y: (anchor.y - this.pan.y) / this.renderScale(),
    };
    this.scale = nextScale;
    this.pan = {
      x: anchor.x - contentPoint.x * this.renderScale(),
      y: anchor.y - contentPoint.y * this.renderScale(),
    };
    this.applyTransform();
  },

  fitToContent() {
    if (!this.items?.length) {
      this.scale = 1 / mapBaseScale;
      this.pan = { x: 0, y: 0 };
      this.applyTransform();
      return;
    }

    const width = Number(this.el.dataset.mapWidth);
    const height = Number(this.el.dataset.mapHeight);
    const { reservedLeft, availableWidth } = this.mapInsets(width);
    const bounds = this.itemBounds();

    const contentWidth = Math.max(bounds.contentWidth, 1);
    const contentHeight = Math.max(bounds.contentHeight, 1);
    const visualScale = Math.min(1.35, Math.max(0.35, Math.min(
      availableWidth / contentWidth,
      (height - 80) / contentHeight,
    )));
    this.scale = visualScale / mapBaseScale;
    this.pan = {
      x: reservedLeft + availableWidth / 2 - (bounds.minX + contentWidth / 2) * this.renderScale(),
      y: height / 2 - (bounds.minY + contentHeight / 2) * this.renderScale(),
    };
    this.applyTransform();
  },

  setDefaultView() {
    if (!this.items?.length) {
      this.scale = 1;
      this.pan = { x: 0, y: 0 };
      this.applyTransform();
      return;
    }

    const width = Number(this.el.dataset.mapWidth);
    const height = Number(this.el.dataset.mapHeight);
    const { reservedLeft, availableWidth } = this.mapInsets(width);
    const bounds = this.itemBounds();

    this.scale = 1;
    this.pan = {
      x: reservedLeft + availableWidth / 2 - (bounds.minX + bounds.contentWidth / 2) * this.renderScale(),
      y: height / 2 - (bounds.minY + bounds.contentHeight / 2) * this.renderScale(),
    };
    this.applyTransform();
  },

  mapInsets(width) {
    const svgRect = this.svg.getBoundingClientRect();
    const viewBoxPerPixel = width / Math.max(svgRect.width, 1);
    const leftSidebar = document.querySelector('[data-map-sidebar-side="left"]');
    const rightSidebar = document.querySelector('[data-map-sidebar-side="right"]');
    const leftOverlay = leftSidebar && !leftSidebar.classList.contains("is-collapsed")
      ? Math.max(0, leftSidebar.getBoundingClientRect().right - svgRect.left)
      : 0;
    const rightOverlay = rightSidebar && !rightSidebar.classList.contains("is-collapsed")
      ? Math.max(0, svgRect.right - rightSidebar.getBoundingClientRect().left)
      : 0;
    const reservedLeft = leftOverlay * viewBoxPerPixel + 40 * viewBoxPerPixel;
    const reservedRight = rightOverlay * viewBoxPerPixel + 40 * viewBoxPerPixel;

    return {
      reservedLeft,
      availableWidth: Math.max(width - reservedLeft - reservedRight, 1),
    };
  },

  itemBounds() {
    const layoutItems = [
      ...this.machines,
      ...this.el.querySelectorAll('[data-map-item-kind="proxy"]'),
    ];
    const bounds = layoutItems.reduce((result, item) => {
      const position = item.dataset.mapItemKind === "node"
        ? this.positions.get(this.itemKey(item))
        : { x: Number(item.dataset.mapX), y: Number(item.dataset.mapY) };
      const itemWidth = Number(item.dataset.mapBoxWidth) || 0;
      const itemHeight = Number(item.dataset.mapBoxHeight) || 0;
      return {
        minX: Math.min(result.minX, position.x),
        minY: Math.min(result.minY, position.y),
        maxX: Math.max(result.maxX, position.x + itemWidth),
        maxY: Math.max(result.maxY, position.y + itemHeight),
      };
    }, { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity });

    if (!Number.isFinite(bounds.minX)) {
      return { minX: 0, minY: 0, maxX: 1, maxY: 1, contentWidth: 1, contentHeight: 1 };
    }

    return {
      ...bounds,
      contentWidth: Math.max(bounds.maxX - bounds.minX, 1),
      contentHeight: Math.max(bounds.maxY - bounds.minY, 1),
    };
  },

  resetLayout() {
    this.positions.clear();
    this.syncItems();
    this.scale = 1;
    this.clearSelection();
    this.setDefaultView();
  },

  viewPoint(clientX, clientY) {
    const matrix = this.svg.getScreenCTM?.();
    if (matrix && typeof DOMPoint !== "undefined" && typeof matrix.inverse === "function") {
      const point = new DOMPoint(clientX, clientY).matrixTransform(matrix.inverse());
      return { x: point.x, y: point.y };
    }

    const rect = this.svg.getBoundingClientRect();
    const width = Number(this.el.dataset.mapWidth);
    const height = Number(this.el.dataset.mapHeight);
    return {
      x: (clientX - rect.left) * width / Math.max(rect.width, 1),
      y: (clientY - rect.top) * height / Math.max(rect.height, 1),
    };
  },

  applyTransform() {
    this.viewport.setAttribute("transform", `translate(${this.pan.x} ${this.pan.y}) scale(${this.renderScale()})`);
    this.machines?.forEach((machine) => {
      this.applyItemPosition(machine, this.positions.get(this.itemKey(machine)));
    });
    this.updateFlowEdges();
    const zoom = this.el.querySelector("[data-map-zoom]");
    if (zoom) zoom.textContent = `${Math.round(this.scale * 100)}%`;
  },

  renderScale() {
    return this.scale * mapBaseScale;
  },

  applyItemPosition(item, position) {
    if (!position) return;
    item.setAttribute("transform", `translate(${position.x} ${position.y})`);
  },

  flowPoint(item) {
    const kind = item.dataset.mapItemKind;
    const position = kind === "node"
      ? this.positions.get(this.itemKey(item))
      : { x: Number(item.dataset.mapX), y: Number(item.dataset.mapY) };
    const width = Number(item.dataset.mapBoxWidth) || 0;
    const height = Number(item.dataset.mapBoxHeight) || 0;

    return {
      top: { x: position.x + width / 2, y: position.y },
      bottom: { x: position.x + width / 2, y: position.y + height },
    };
  },

  updateFlowEdges() {
    this.el?.querySelectorAll("[data-map-flow]").forEach((edge) => {
      const source = this.findItem("proxy", edge.dataset.mapFlowSource);
      const target = this.findItem("node", edge.dataset.mapFlowTarget);
      if (!source || !target) return;

      const start = this.flowPoint(source).bottom;
      const finish = this.flowPoint(target).top;
      const bendY = start.y + Math.max(24, (finish.y - start.y) / 2);
      edge.setAttribute(
        "d",
        `M ${start.x} ${start.y} C ${start.x} ${bendY}, ${finish.x} ${bendY}, ${finish.x} ${finish.y}`,
      );
    });
  },

  selectItem(item, focus = true) {
    this.items.forEach((candidate) => candidate.classList.remove("is-selected"));
    item.classList.add("is-selected");
    this.selected = {
      kind: item.dataset.mapItemKind,
      key: item.dataset.mapItemKey,
    };

    const empty = this.el.querySelector("[data-map-inspector-empty]");
    const details = this.el.querySelector("[data-map-inspector-details]");
    this.el.querySelector("[data-map-inspector]").classList.remove("is-empty");
    empty.hidden = true;
    details.hidden = false;
    this.el.querySelector("[data-inspector-kind]").textContent = item.dataset.mapItemKind === "node"
      ? "Node"
      : item.dataset.mapItemKind === "proxy" ? "Proxy" : "Service slot";
    this.el.querySelector("[data-inspector-title]").textContent = item.dataset.mapTitle;
    this.el.querySelector("[data-inspector-status]").textContent = item.dataset.mapStatus;
    this.el.querySelector("[data-inspector-subtitle]").textContent = item.dataset.mapSubtitle;
    this.el.querySelector("[data-inspector-detail]").textContent = item.dataset.mapDetail;

    if (focus) item.focus({ preventScroll: true });
  },

  clearSelection() {
    this.selected = null;
    this.items?.forEach((item) => item.classList.remove("is-selected"));
    this.el.querySelector("[data-map-inspector]").classList.add("is-empty");
    this.el.querySelector("[data-map-inspector-empty]").hidden = false;
    this.el.querySelector("[data-map-inspector-details]").hidden = true;
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { MapSidebar, NetworkMap },
});

liveSocket.connect();
window.liveSocket = liveSocket;
