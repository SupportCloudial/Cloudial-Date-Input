/**
 * @description a util class for storing Constants & Functions
 */

const reverse = (str) => str.split("").reverse().join(""); // Reverse all the characters in a string
const baseURL = window.location.hostname || "LWR"; // LWR Experience does not support window.xxx
console.log("DATATABLE: environment baseURL", baseURL);

let myDomain;
let isCommunity = false;
let isFlowBuilder = false;

if (baseURL.includes("--c.visualforce.") || baseURL.includes("--c.vf.")) {
  // Running in Flow Builder || Flow Builder (Enhanced Domain)
  // Get domain url by replacing the last occurance of '--c' in the current url
  myDomain =
    "https://" +
    reverse(
      reverse(window.location.hostname.split(".")[0]).replace(
        reverse("--c"),
        ""
      )
    );
} else if (baseURL.includes(".lightning.")) {
  // Running in Lightning
  myDomain = "https://" + window.location.hostname.split(".")[0];
  if (baseURL.includes(".sandbox.")) {
    // Running in a sandbox with Enhanced Domain enabled
    myDomain += ".sandbox";
  }
} else {
  // Running in a Community or Flow Builder
  myDomain = window.location.href; // https://<domain>.<instance>.force.com/<site title>/s/
  myDomain = myDomain.split("/s/")[0] + "/s/"; // v3.4.5 Remove everything after the /s/ (non-home pages)
  isCommunity = true;
}
if (myDomain.includes("flow/runtime") || myDomain.includes("/flow/")) {
  // Running in Flow Builder || Flow Builder (Enhanced Domain)
  myDomain = baseURL;
  isCommunity = false;
  isFlowBuilder = true;
}
console.log("DATATABLE: myDomain:", myDomain);
console.log(
  "DATATABLE: isCommunity, isFlowBuilder:",
  isCommunity,
  isFlowBuilder
);

const getConstants = () => {
  return {
    VERSION_NUMBER: "4.3.0", // Current Source Code Version #
    MAXROWCOUNT: 2000, // Limit the total number of records to be handled by this component
    ROUNDWIDTH: 5, // Used to round off the column widths during Config Mode to nearest value
    WIZROWCOUNT: 6, // Number of records to display in the Column Wizard datatable
    MYDOMAIN: myDomain, // Used for building links for lookup fields
    ISCOMMUNITY: isCommunity, // Used for building links for lookup fields
    ISFLOWBUILDER: isFlowBuilder, // Used for building links for lookup fields
    CB_TRUE: "CB_TRUE", // Used with fsc_flowCheckbox component
    CB_FALSE: "CB_FALSE", // Used with fsc_flowCheckbox component
    CB_ATTRIB_PREFIX: "cb_", // Used with fsc_flowCheckbox component
    MIN_SEARCH_TERM_SIZE: 2, // Set the minimum number of characters required to start searching
    SEARCH_WAIT_TIME: 300, // Set the delay to start searching while user is typing a search term
    RECORDS_PER_PAGE: 10, // Default number of records per page for pagination
    REMOVE_ROW_LABEL: "Remove Row", // Default label for the Remove Row button
    REMOVE_ROW_ICON: "utility:close", // Default Icon for the Remove Row button
    REMOVE_ROW_COLOR: "remove-icon", // Default Color for the Remove Row button
    REMOVE_ROW_SIDE: "Right", // Default Side for the Remove Row button
    DEBUG_INFO_PREFIX: "DATATABLE: ", // Prefix to be used for debug info in the console and debug logs
    SHOW_DEBUG_INFO: false // Set to true to show sensitive debug info in the console and debug logs
  };
};

const columnValue = (attrib) => {
  // Extract the value from the column attribute
  return attrib.slice(attrib.search(":") + 1);
};

const removeSpaces = (string) => {
  return string
    .replace(/, | ,/g, ",")
    .replace(/: | :/g, ":")
    .replace(/{ | {/g, "{")
    .replace(/} | }/g, "}")
    .replace(/; | ;/g, ";");
};

const convertFormat = (colType) => {
  // Set Input Formatter value for different number types
  switch (colType) {
    case "currency":
      return "currency";
    case "percent":
      // return 'percent-fixed';  // This would be to enter 35 to get 35% (0.35)
      return "percent";
    default:
      return null;
  }
};

const convertType = (colType) => {
  // Set Input Type based on column Data Type
  switch (colType) {
    case "boolean":
      return "text";
    case "date":
      return "date";
    case "date-local":
      return "date";
    case "datetime":
      return "datetime";
    case "time":
      return "time";
    case "email":
      return "email";
    case "phone":
      return "tel";
    case "url":
      return "url";
    case "number":
      return "number";
    case "currency":
      return "number";
    case "percent":
      return "number";
    case "text":
      return "text";
    default:
      return "richtext";
  }
};

const convertTime = (that, dtValue) => {
  // Return a Salesforce formatted time value based a datetime value
  const dtv = new Date(dtValue);
  const hours = dtv.getHours() - that.timezoneOffset / 2880000;
  let timeString = ("00" + hours).slice(-2) + ":";
  timeString += ("00" + dtv.getMinutes()).slice(-2) + ":";
  timeString += ("00" + dtv.getSeconds()).slice(-2) + ".";
  timeString += ("000" + dtv.getMilliseconds()).slice(-3);
  timeString += "Z";
  return timeString;
};

const findRowIndexById = (that, collection, id) => {
  let idx = -1;
  collection.some((row, index) => {
    if (row[that.keyField] === id) {
      idx = index;
      return true;
    }
    return false;
  });
  return idx;
};

const removeRowFromCollection = (that, collection, keyValue) => {
  const index = findRowIndexById(that, collection, keyValue);
  let result = collection;
  if (index !== -1) {
    result = collection.slice(0, index).concat(collection.slice(index + 1));
  }
  return result;
};

const replaceRowInCollection = (that, original, updated, keyValue) => {
  // Replace the matching row in the original collection with the matching row from the updated collection
  const oindex = findRowIndexById(that, original, keyValue);
  const uindex = findRowIndexById(that, updated, keyValue);
  let result = original;
  if (oindex !== -1 && uindex !== -1) {
    result = original
      .slice(0, oindex)
      .concat(updated.slice(uindex, uindex + 1))
      .concat(original.slice(oindex + 1));
  }
  return result;
};

const TOOLTIP_STYLE_ID = "ers-tooltip-portal-styles";
let tooltipPortalStylesInjected = false;

const TOOLTIP_PORTAL_STYLES = `
.ers-tooltip-portal {
  position: fixed;
  left: -10000px;
  top: -10000px;
  opacity: 0;
  pointer-events: none;
  z-index: 100000;
  max-width: min(300px, calc(100vw - 16px));
  min-width: 140px;
  padding: 6px 10px;
  border-radius: 8px;
  background: #f8fafc;
  color: #1f2937;
  border: 1px solid #dbe2ea;
  box-shadow: 0 8px 24px rgba(15, 23, 42, 0.22);
  font-size: 0.75rem;
  line-height: 1.35;
  font-weight: 500;
  text-align: center;
  white-space: normal;
  transition: opacity 140ms ease;
}
.ers-tooltip-portal.is-visible {
  opacity: 1;
}
.ers-tooltip-portal::after {
  content: "";
  position: absolute;
  left: var(--ers-tooltip-arrow-left, 50%);
  top: 100%;
  transform: translateX(-50%);
  border: 6px solid transparent;
  border-top-color: #f8fafc;
}
.ers-tooltip-portal--below::after {
  top: auto;
  bottom: 100%;
  border-top-color: transparent;
  border-bottom-color: #f8fafc;
}
`;

const ensureTooltipPortalStyles = () => {
  if (typeof document === "undefined" || tooltipPortalStylesInjected) return;
  const style = document.createElement("style");
  style.id = TOOLTIP_STYLE_ID;
  style.textContent = TOOLTIP_PORTAL_STYLES;
  document.head.appendChild(style);
  tooltipPortalStylesInjected = true;
};

const getTooltipAnchorRect = (anchorEl) => {
  if (!anchorEl) {
    return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
  }
  const visual =
    anchorEl.querySelector?.("lightning-icon, svg.slds-icon") || anchorEl;
  return visual.getBoundingClientRect();
};

const positionTooltipBubble = (anchorEl, bubbleEl) => {
  const ar = getTooltipAnchorRect(anchorEl);
  const gap = 8;
  const minEdge = 6;
  const cx = ar.left + ar.width / 2;
  const viewportWidth =
    window.innerWidth || document.documentElement.clientWidth || 0;

  bubbleEl.style.position = "fixed";
  bubbleEl.style.zIndex = "100000";
  bubbleEl.style.visibility = "hidden";
  bubbleEl.style.opacity = "1";
  bubbleEl.style.transform = "translate(0, -100%)";
  bubbleEl.style.top = `${ar.top - gap}px`;
  bubbleEl.style.left = `${cx}px`;

  const bubbleWidth = bubbleEl.offsetWidth || 0;
  const clampedLeft = Math.min(
    Math.max(cx - bubbleWidth / 2, minEdge),
    Math.max(minEdge, viewportWidth - minEdge - bubbleWidth)
  );
  bubbleEl.style.left = `${clampedLeft}px`;

  const arrowInset = 12;
  const arrowLeftPx = Math.min(
    Math.max(cx - clampedLeft, arrowInset),
    Math.max(arrowInset, bubbleWidth - arrowInset)
  );
  bubbleEl.style.setProperty(
    "--ers-tooltip-arrow-left",
    `${Math.round(arrowLeftPx)}px`
  );

  const h = bubbleEl.offsetHeight;
  if (ar.top - gap - h < minEdge) {
    bubbleEl.classList.add("ers-tooltip-portal--below");
    bubbleEl.style.transform = "translate(0, 0)";
    bubbleEl.style.top = `${ar.bottom + gap}px`;
  } else {
    bubbleEl.classList.remove("ers-tooltip-portal--below");
    bubbleEl.style.transform = "translate(0, -100%)";
    bubbleEl.style.top = `${ar.top - gap}px`;
  }
  bubbleEl.style.visibility = "visible";
};

const createPortalTooltipBubble = (message) => {
  ensureTooltipPortalStyles();
  const bubble = document.createElement("span");
  bubble.className = "ers-tooltip-portal";
  bubble.setAttribute("role", "tooltip");
  bubble.textContent = message || "";
  document.body.appendChild(bubble);
  return bubble;
};

const destroyPortalTooltipBubble = (bubble) => {
  if (bubble?.parentNode) {
    bubble.parentNode.removeChild(bubble);
  }
};

export {
  getConstants,
  columnValue,
  removeSpaces,
  convertFormat,
  convertType,
  convertTime,
  removeRowFromCollection,
  replaceRowInCollection,
  findRowIndexById,
  createPortalTooltipBubble,
  destroyPortalTooltipBubble,
  positionTooltipBubble
};
