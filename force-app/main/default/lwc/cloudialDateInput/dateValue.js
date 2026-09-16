/* eslint-disable @salesforce/lightning/prefer-i18n-service -- Intl is required to infer locale date order and normalize localized digits without converting the ISO public value. */
const ISO_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const DISPLAY_FORMATS = new Set([
  "locale",
  "DD.MM.YYYY",
  "DD/MM/YYYY",
  "MM/DD/YYYY",
  "YYYY-MM-DD"
]);
const formatterCache = new Map();
const dateOrderCache = new Map();
const digitMapCache = new Map();

export function isValidIso(value) {
  const match = String(value || "").match(ISO_PATTERN);
  if (!match) {
    return false;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12 || day < 1) {
    return false;
  }
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [
    31,
    leapYear ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31
  ];
  return day <= daysInMonth[month - 1];
}

export function normalizeIso(value) {
  const candidate = String(value || "").trim();
  return isValidIso(candidate) ? candidate : "";
}

export function normalizeDisplayFormat(value) {
  return DISPLAY_FORMATS.has(value) ? value : "locale";
}

export function resolveLocale(candidate, fallback) {
  const requested = candidate || fallback;
  try {
    getDateFormatter(requested);
    return requested;
  } catch {
    return fallback;
  }
}

export function replaceMessageParameter(message, value) {
  return String(message).replace("{0}", value);
}

export function formatIsoDate(isoValue, displayFormat, locale) {
  if (!isValidIso(isoValue)) {
    return "";
  }
  const [year, month, day] = isoValue.split("-");
  switch (displayFormat) {
    case "DD.MM.YYYY":
      return `${day}.${month}.${year}`;
    case "DD/MM/YYYY":
      return `${day}/${month}/${year}`;
    case "MM/DD/YYYY":
      return `${month}/${day}/${year}`;
    case "YYYY-MM-DD":
      return isoValue;
    default: {
      const date = new Date(0);
      date.setUTCHours(0, 0, 0, 0);
      date.setUTCFullYear(Number(year), Number(month) - 1, Number(day));
      return getDateFormatter(locale).format(date);
    }
  }
}

export function parseDisplayDate(displayValue, displayFormat, locale) {
  const text = String(displayValue || "").trim();
  if (!text) {
    return "";
  }

  const order = getDateOrder(displayFormat, locale);
  const normalizedText = normalizeLocaleDigits(text, locale);
  const values = normalizedText.match(/\d+/g);
  if (!values || values.length !== 3) {
    return null;
  }

  const parts = Object.fromEntries(
    order.map((part, index) => [part, values[index]])
  );
  if (String(parts.year).length !== 4) {
    return null;
  }
  const normalized = `${String(parts.year).padStart(4, "0")}-${String(
    parts.month
  ).padStart(2, "0")}-${String(parts.day).padStart(2, "0")}`;
  return isValidIso(normalized) ? normalized : null;
}

function getDateOrder(displayFormat, locale) {
  switch (displayFormat) {
    case "DD.MM.YYYY":
    case "DD/MM/YYYY":
      return ["day", "month", "year"];
    case "MM/DD/YYYY":
      return ["month", "day", "year"];
    case "YYYY-MM-DD":
      return ["year", "month", "day"];
    default:
      if (!dateOrderCache.has(locale)) {
        const sample = new Date(Date.UTC(2006, 10, 22));
        const order = getDateFormatter(locale)
          .formatToParts(sample)
          .filter((part) => ["day", "month", "year"].includes(part.type))
          .map((part) => part.type);
        dateOrderCache.set(locale, order);
      }
      return dateOrderCache.get(locale);
  }
}

function getDateFormatter(locale) {
  if (!formatterCache.has(locale)) {
    formatterCache.set(
      locale,
      new Intl.DateTimeFormat(locale, {
        calendar: "gregory",
        day: "2-digit",
        month: "2-digit",
        year: "numeric",
        timeZone: "UTC"
      })
    );
  }
  return formatterCache.get(locale);
}

function normalizeLocaleDigits(value, locale) {
  if (!digitMapCache.has(locale)) {
    const formatter = new Intl.NumberFormat(locale, { useGrouping: false });
    const digits = new Map();
    for (let digit = 0; digit <= 9; digit += 1) {
      digits.set(formatter.format(digit), String(digit));
    }
    digitMapCache.set(locale, digits);
  }
  const digitMap = digitMapCache.get(locale);
  return [...value]
    .map((character) => digitMap.get(character) ?? character)
    .join("");
}
