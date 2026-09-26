/* @ds-bundle: {"format":4,"namespace":"UpOnlyDesignSystem_ed44c6","components":[{"name":"CircleButton","sourcePath":"components/buttons/CircleButton.jsx"},{"name":"PrivacyButton","sourcePath":"components/buttons/CircleButton.jsx"},{"name":"PillButton","sourcePath":"components/buttons/PillButton.jsx"},{"name":"PillMenu","sourcePath":"components/buttons/PillMenu.jsx"},{"name":"Breakdown","sourcePath":"components/charts/Breakdown.jsx"},{"name":"LineChart","sourcePath":"components/charts/LineChart.jsx"},{"name":"SearchField","sourcePath":"components/controls/SearchField.jsx"},{"name":"Segments","sourcePath":"components/controls/Segments.jsx"},{"name":"Switch","sourcePath":"components/controls/Switch.jsx"},{"name":"ICON_CDN","sourcePath":"components/core/Icon.jsx"},{"name":"Icon","sourcePath":"components/core/Icon.jsx"},{"name":"Amount","sourcePath":"components/data/Amount.jsx"},{"name":"AssetBadge","sourcePath":"components/data/AssetBadge.jsx"},{"name":"ChangeBadge","sourcePath":"components/data/ChangeBadge.jsx"},{"name":"HeadlineStats","sourcePath":"components/data/HeadlineStats.jsx"},{"name":"StatTile","sourcePath":"components/data/StatTile.jsx"},{"name":"SymbolBadge","sourcePath":"components/data/SymbolBadge.jsx"},{"name":"ValueRow","sourcePath":"components/data/ValueRow.jsx"},{"name":"HoldingsHeader","sourcePath":"components/lists/HoldingRow.jsx"},{"name":"HoldingRow","sourcePath":"components/lists/HoldingRow.jsx"},{"name":"Row","sourcePath":"components/lists/Row.jsx"},{"name":"RowMenu","sourcePath":"components/lists/Row.jsx"},{"name":"SourceRow","sourcePath":"components/lists/SourceRow.jsx"},{"name":"PageHeader","sourcePath":"components/navigation/PageHeader.jsx"},{"name":"SetupHeader","sourcePath":"components/navigation/SetupHeader.jsx"},{"name":"SwitcherTitle","sourcePath":"components/navigation/SwitcherTitle.jsx"},{"name":"AttentionBanner","sourcePath":"components/surfaces/AttentionBanner.jsx"},{"name":"Backdrop","sourcePath":"components/surfaces/Backdrop.jsx"},{"name":"Card","sourcePath":"components/surfaces/Card.jsx"},{"name":"Confirmation","sourcePath":"components/surfaces/Confirmation.jsx"},{"name":"EmptyState","sourcePath":"components/surfaces/EmptyState.jsx"},{"name":"Notice","sourcePath":"components/surfaces/Notice.jsx"},{"name":"Panel","sourcePath":"components/surfaces/Panel.jsx"}],"sourceHashes":{"components/buttons/CircleButton.jsx":"16e0d4f7bc82","components/buttons/PillButton.jsx":"d51fb6e665e8","components/buttons/PillMenu.jsx":"f3a2af0ae2d2","components/charts/Breakdown.jsx":"b84caa3ea08f","components/charts/LineChart.jsx":"db43d484036f","components/controls/SearchField.jsx":"cd393f974f94","components/controls/Segments.jsx":"17cb0a6e88e3","components/controls/Switch.jsx":"ccd761f6ba39","components/core/Icon.jsx":"718ef0561251","components/data/Amount.jsx":"9a2ac98c5d6e","components/data/AssetBadge.jsx":"665bde7ec529","components/data/ChangeBadge.jsx":"32bde80e77c6","components/data/HeadlineStats.jsx":"457f76882cae","components/data/StatTile.jsx":"c1a7f4b77753","components/data/SymbolBadge.jsx":"ddcf014a5f45","components/data/ValueRow.jsx":"85c10967397c","components/lists/HoldingRow.jsx":"df25eff6d28b","components/lists/Row.jsx":"b82cd6d8f4aa","components/lists/SourceRow.jsx":"f96e1b17a63a","components/navigation/PageHeader.jsx":"bb32210245e1","components/navigation/SetupHeader.jsx":"71a6f6e07b2e","components/navigation/SwitcherTitle.jsx":"b52b06bc8f3a","components/surfaces/AttentionBanner.jsx":"a155f2fe77a2","components/surfaces/Backdrop.jsx":"9f99081ca913","components/surfaces/Card.jsx":"65e675164ba2","components/surfaces/Confirmation.jsx":"a7f702febc71","components/surfaces/EmptyState.jsx":"56184539920c","components/surfaces/Notice.jsx":"51037b8391e4","components/surfaces/Panel.jsx":"edf21fb8404e","ui_kits/menu-bar/AddPage.jsx":"65b5af86bef5","ui_kits/menu-bar/App.jsx":"d5a67d7c8bc2","ui_kits/menu-bar/Header.jsx":"4be2bdc8bc1d","ui_kits/menu-bar/HomePage.jsx":"8ed87fc5edc3","ui_kits/menu-bar/ManagePage.jsx":"a06ad764e71d","ui_kits/menu-bar/PortfolioPage.jsx":"5f5c02209834","ui_kits/menu-bar/SettingsPage.jsx":"323097a5b7a9","ui_kits/menu-bar/SwitcherPage.jsx":"ee4eed11cd00","ui_kits/menu-bar/data.js":"53d8f4a82056"},"inlinedExternals":[],"unexposedExports":[{"name":"arrowPercent","sourcePath":"components/data/Amount.jsx"},{"name":"compactFigure","sourcePath":"components/data/Amount.jsx"},{"name":"formatExact","sourcePath":"components/data/Amount.jsx"},{"name":"formatMagnitude","sourcePath":"components/data/Amount.jsx"},{"name":"formatMoney","sourcePath":"components/data/Amount.jsx"},{"name":"percentages","sourcePath":"components/charts/Breakdown.jsx"},{"name":"signedColor","sourcePath":"components/data/Amount.jsx"}]} */

(() => {

const __ds_ns = (window.UpOnlyDesignSystem_ed44c6 = window.UpOnlyDesignSystem_ed44c6 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/charts/Breakdown.jsx
try { (() => {
const {
  useEffect,
  useState
} = React;
function percentages(values) {
  const parts = values.map(v => Math.max(v, 0)),
    total = parts.reduce((a, b) => a + b, 0);
  if (!total) return values.map(() => 0);
  const exact = parts.map(v => v / total * 100),
    res = exact.map(Math.floor);
  const order = exact.map((e, i) => i).sort((a, b) => exact[b] - res[b] - (exact[a] - res[a]) || a - b);
  for (const i of order.slice(0, Math.max(0, 100 - res.reduce((a, b) => a + b, 0)))) res[i]++;
  return res;
}
/** What the total is made of: a donut that sweeps in with the largest share at its centre, and a legend beside it, in one card. */
function Breakdown({
  slices = [],
  diameter = 112,
  style
}) {
  const [shown, setShown] = useState(false);
  useEffect(() => {
    const t = requestAnimationFrame(() => setShown(true));
    return () => cancelAnimationFrame(t);
  }, []);
  const pct = percentages(slices.map(s => s.value));
  const total = Math.max(slices.reduce((a, s) => a + s.value, 0), 1);
  let acc = 0;
  const ends = slices.map(s => acc += s.value / total);
  const largest = pct.indexOf(Math.max(...pct));
  const gap = slices.length > 1 ? 0.012 : 0,
    big = diameter > 90,
    line = big ? 12 : 10;
  const r = (diameter - line) / 2,
    C = 2 * Math.PI * r;
  const label = p => p === 0 ? '<1%' : p + '%';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 20,
      padding: '14px 16px',
      background: 'var(--surface-card)',
      borderRadius: 'var(--radius-card)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      width: diameter,
      height: diameter,
      flex: 'none'
    },
    "aria-hidden": "true"
  }, /*#__PURE__*/React.createElement("svg", {
    width: diameter,
    height: diameter,
    style: {
      transform: 'rotate(-90deg)',
      display: 'block'
    }
  }, /*#__PURE__*/React.createElement("defs", null, slices.map((s, i) => /*#__PURE__*/React.createElement("linearGradient", {
    key: i,
    id: 'uob' + i + diameter,
    x1: "0",
    y1: "0",
    x2: "1",
    y2: "0"
  }, /*#__PURE__*/React.createElement("stop", {
    offset: "0",
    style: {
      stopColor: s.color
    }
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "1",
    style: {
      stopColor: s.color,
      stopOpacity: 0.78
    }
  })))), /*#__PURE__*/React.createElement("circle", {
    cx: diameter / 2,
    cy: diameter / 2,
    r: r,
    fill: "none",
    stroke: "rgba(255,255,255,0.06)",
    strokeWidth: line
  }), slices.map((s, i) => {
    const start = (i === 0 ? 0 : ends[i - 1]) + gap / 2,
      end = Math.max(start, ends[i] - gap / 2);
    const len = shown ? (end - start) * C : 0;
    return /*#__PURE__*/React.createElement("circle", {
      key: i,
      cx: diameter / 2,
      cy: diameter / 2,
      r: r,
      fill: "none",
      stroke: 'url(#uob' + i + diameter + ')',
      strokeWidth: line,
      strokeDasharray: len + ' ' + C,
      strokeDashoffset: -start * C,
      style: {
        transition: 'stroke-dasharray 700ms cubic-bezier(0.25,1,0.4,1)'
      }
    });
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: line + 3,
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 ' + (big ? 19 : 15) + 'px/1.1 var(--font-sans)',
      fontVariantNumeric: 'tabular-nums'
    }
  }, slices.length ? label(pct[largest]) : ''), /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 ' + (big ? 10 : 9) + 'px/1.2 var(--font-sans)',
      color: 'var(--text-secondary)',
      whiteSpace: 'nowrap'
    }
  }, slices.length ? slices[largest].name : ''))), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0,
      display: 'flex',
      flexDirection: 'column',
      gap: big ? 10 : 7
    }
  }, slices.map((s, i) => /*#__PURE__*/React.createElement("div", {
    key: s.name,
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      font: '12px/1.2 var(--font-sans)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 10,
      height: 10,
      borderRadius: 2.5,
      background: s.color,
      flex: 'none'
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'rgba(255,255,255,0.72)',
      flex: 1,
      minWidth: 0,
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, s.name), /*#__PURE__*/React.createElement("span", {
    style: {
      fontWeight: 600,
      fontVariantNumeric: 'tabular-nums'
    }
  }, label(pct[i]))))));
}
Object.assign(__ds_scope, { percentages, Breakdown });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/charts/Breakdown.jsx", error: String((e && e.message) || e) }); }

// components/controls/Segments.jsx
try { (() => {
/** Plain labels with the chosen one in a soft pill that slides to the next choice: 24H 7D 30D 1Y All. */
function Segments({
  options = ['24H', '7D', '30D', '1Y', 'All'],
  value,
  onChange,
  label = 'Chart range',
  style
}) {
  const n = options.length;
  const i = Math.max(0, options.indexOf(value != null ? value : options[0]));
  const w = 'calc((100% - ' + 2 * (n - 1) + 'px) / ' + n + ')';
  return /*#__PURE__*/React.createElement("div", {
    role: "radiogroup",
    "aria-label": label,
    style: {
      position: 'relative',
      display: 'grid',
      gridTemplateColumns: 'repeat(' + n + ', minmax(0,1fr))',
      gap: 2,
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: 0,
      bottom: 0,
      width: w,
      left: 'calc(' + i + ' * (' + w + ' + 2px))',
      borderRadius: 999,
      background: 'var(--surface-segment)',
      transition: 'left 250ms var(--ease-snappy)'
    }
  }), options.map(o => {
    const chosen = o === options[i];
    return /*#__PURE__*/React.createElement("button", {
      key: o,
      type: "button",
      role: "radio",
      "aria-checked": chosen,
      onClick: () => onChange && onChange(o),
      style: {
        position: 'relative',
        minHeight: 26,
        border: 'none',
        background: 'none',
        borderRadius: 999,
        cursor: 'pointer',
        padding: 0,
        font: (chosen ? 600 : 500) + ' 11px/1 var(--font-sans)',
        fontVariantNumeric: 'tabular-nums',
        color: chosen ? 'var(--text-primary)' : 'var(--text-secondary)',
        transition: 'color 200ms'
      }
    }, o);
  }));
}
Object.assign(__ds_scope, { Segments });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/controls/Segments.jsx", error: String((e && e.message) || e) }); }

// components/controls/Switch.jsx
try { (() => {
/** The system switch at small size, tinted brand green. */
function Switch({
  on = false,
  onChange,
  disabled = false,
  label,
  style
}) {
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    role: "switch",
    "aria-checked": on,
    "aria-label": label,
    disabled: disabled,
    onClick: () => onChange && onChange(!on),
    style: {
      position: 'relative',
      width: 32,
      height: 18,
      flex: 'none',
      border: 'none',
      padding: 0,
      borderRadius: 999,
      cursor: disabled ? 'default' : 'pointer',
      background: on ? 'var(--color-brand)' : 'rgba(255,255,255,0.16)',
      boxShadow: on ? 'none' : 'inset 0 0 0 0.5px rgba(255,255,255,0.12)',
      opacity: disabled ? 0.4 : 1,
      transition: 'background 200ms var(--ease-snappy)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: 1,
      left: on ? 15 : 1,
      width: 16,
      height: 16,
      borderRadius: '50%',
      background: '#fff',
      boxShadow: '0 1px 2px rgba(0,0,0,0.3)',
      transition: 'left 200ms var(--ease-snappy)'
    }
  }));
}
Object.assign(__ds_scope, { Switch });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/controls/Switch.jsx", error: String((e && e.message) || e) }); }

// components/core/Icon.jsx
try { (() => {
// SF Symbols have no web build; each symbol the app uses maps to its nearest Lucide glyph, drawn as a CSS mask so it takes currentColor.
const SYMBOLS = {
  'chevron.left': 'chevron-left',
  'chevron.right': 'chevron-right',
  'chevron.down': 'chevron-down',
  plus: 'plus',
  eye: 'eye',
  'eye.slash': 'eye-off',
  ellipsis: 'ellipsis',
  xmark: 'x',
  checkmark: 'check',
  'arrow.up': 'arrow-up',
  'arrow.down': 'arrow-down',
  magnifyingglass: 'search',
  'xmark.circle.fill': 'circle-x',
  'building.columns.fill': 'landmark',
  'bitcoinsign.circle.fill': 'bitcoin',
  'square.stack.3d.up.fill': 'layers',
  'arrow.up.arrow.down': 'arrow-up-down',
  'arrow.up.arrow.down.circle.fill': 'arrow-up-down',
  'building.2.fill': 'building-2',
  'square.grid.2x2.fill': 'layout-grid',
  'doc.text.fill': 'file-text',
  tablecells: 'table',
  'gearshape.fill': 'settings',
  'list.bullet.rectangle.fill': 'list',
  'arrow.triangle.2.circlepath': 'refresh-cw',
  'arrow.clockwise': 'rotate-cw',
  'exclamationmark.triangle': 'triangle-alert',
  'xmark.octagon': 'octagon-x',
  lock: 'lock',
  'lock.fill': 'lock',
  'slider.horizontal.3': 'sliders-horizontal',
  'chart.line.uptrend.xyaxis': 'chart-line',
  'square.and.pencil': 'square-pen',
  cart: 'shopping-cart',
  'checkmark.circle.fill': 'circle-check',
  'doc.on.doc': 'copy',
  'key.fill': 'key-round',
  'externaldrive.fill': 'hard-drive',
  'arrow.left.arrow.right': 'arrow-left-right'
};
const ICON_CDN = 'assets/icons/';
function Icon({
  name = 'plus',
  size = 14,
  color = 'currentColor',
  style
}) {
  const url = 'url(' + ICON_CDN + (SYMBOLS[name] || name) + '.svg)';
  return /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      display: 'inline-block',
      width: size,
      height: size,
      flex: 'none',
      backgroundColor: color,
      WebkitMaskImage: url,
      maskImage: url,
      WebkitMaskSize: 'contain',
      maskSize: 'contain',
      WebkitMaskRepeat: 'no-repeat',
      maskRepeat: 'no-repeat',
      WebkitMaskPosition: 'center',
      maskPosition: 'center',
      ...style
    }
  });
}
Object.assign(__ds_scope, { ICON_CDN, Icon });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Icon.jsx", error: String((e && e.message) || e) }); }

// components/buttons/CircleButton.jsx
try { (() => {
const {
  useState
} = React;
const TONES = {
  primary: 'var(--text-primary)',
  secondary: 'var(--text-secondary)',
  brand: 'var(--color-brand)'
};
/** The one round glass header button: Back, +, the eye and "…". */
function CircleButton({
  icon = 'chevron.left',
  label,
  tone = 'primary',
  disabled = false,
  onClick,
  size = 32,
  style
}) {
  const [hover, setHover] = useState(false);
  const [down, setDown] = useState(false);
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    "aria-label": label,
    title: label,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setDown(false);
    },
    onMouseDown: () => setDown(true),
    onMouseUp: () => setDown(false),
    style: {
      width: size,
      height: size,
      borderRadius: '50%',
      border: 'none',
      padding: 0,
      flex: 'none',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      cursor: disabled ? 'default' : 'pointer',
      color: TONES[tone] || tone,
      background: hover && !disabled ? 'var(--glass-bg-hover)' : 'var(--glass-bg)',
      boxShadow: 'var(--glass-border), var(--glass-shadow)',
      backdropFilter: 'var(--glass-blur)',
      WebkitBackdropFilter: 'var(--glass-blur)',
      opacity: disabled ? 0.4 : 1,
      transform: down ? 'scale(0.94)' : 'none',
      transition: 'transform 200ms var(--ease-snappy), background 150ms, color 200ms',
      ...style
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon,
    size: 15
  }));
}
/** The privacy eye: a CircleButton whose eye closes and turns green while values are hidden. */
function PrivacyButton({
  on = false,
  onToggle,
  style
}) {
  return /*#__PURE__*/React.createElement(CircleButton, {
    icon: on ? 'eye.slash' : 'eye',
    tone: on ? 'brand' : 'secondary',
    label: on ? 'Show values' : 'Hide values',
    onClick: onToggle,
    style: style
  });
}
Object.assign(__ds_scope, { CircleButton, PrivacyButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/buttons/CircleButton.jsx", error: String((e && e.message) || e) }); }

// components/buttons/PillButton.jsx
try { (() => {
const {
  useState
} = React;
const SIZES = {
  small: {
    font: 12,
    pad: 12,
    h: 26
  },
  regular: {
    font: 13,
    pad: 16,
    h: 32
  },
  large: {
    font: 14,
    pad: 20,
    h: 40
  }
};
/** The app's two buttons: a white pill for the main action, a dark translucent one beside it. */
function PillButton({
  children,
  variant = 'primary',
  size = 'regular',
  fullWidth = false,
  disabled = false,
  icon,
  onClick,
  style
}) {
  const [down, setDown] = useState(false);
  const s = SIZES[size] || SIZES.regular;
  const primary = variant === 'primary';
  const bg = primary ? disabled ? 'var(--uo-fill-12)' : 'var(--surface-pill-primary)' : 'var(--surface-pill-secondary)';
  const fg = disabled ? 'var(--text-disabled)' : primary ? 'var(--text-on-primary)' : '#FFFFFF';
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    disabled: disabled,
    onClick: onClick,
    onMouseDown: () => setDown(true),
    onMouseUp: () => setDown(false),
    onMouseLeave: () => setDown(false),
    style: {
      display: fullWidth ? 'flex' : 'inline-flex',
      width: fullWidth ? '100%' : undefined,
      alignItems: 'center',
      justifyContent: 'center',
      gap: 6,
      minHeight: s.h,
      padding: '0 ' + s.pad + 'px',
      border: 'none',
      borderRadius: 999,
      background: bg,
      color: fg,
      font: '600 ' + s.font + 'px/1 var(--font-sans)',
      whiteSpace: 'nowrap',
      cursor: disabled ? 'default' : 'pointer',
      opacity: down && !disabled ? 0.75 : 1,
      transition: 'opacity 120ms',
      boxSizing: 'border-box',
      ...style
    }
  }, icon ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon,
    size: s.font + 1
  }) : null, children);
}
Object.assign(__ds_scope, { PillButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/buttons/PillButton.jsx", error: String((e && e.message) || e) }); }

// components/buttons/PillMenu.jsx
try { (() => {
/** A menu that sits in a glass capsule: "All time", "September 2026", "All assets ⌄". */
function PillMenu({
  children,
  quiet = false,
  chevron = false,
  onClick,
  style
}) {
  const h = quiet ? 22 : 26;
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: onClick,
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 4,
      minHeight: h,
      padding: '0 ' + (quiet ? 9 : 10) + 'px',
      border: 'none',
      borderRadius: 999,
      background: 'var(--glass-bg)',
      boxShadow: 'var(--glass-border)',
      backdropFilter: 'var(--glass-blur)',
      WebkitBackdropFilter: 'var(--glass-blur)',
      color: 'var(--text-primary)',
      font: '500 ' + (quiet ? 11 : 12) + 'px/1 var(--font-sans)',
      cursor: 'pointer',
      whiteSpace: 'nowrap',
      ...style
    }
  }, children, chevron ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron.down",
    size: 10,
    color: "var(--text-secondary)"
  }) : null);
}
Object.assign(__ds_scope, { PillMenu });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/buttons/PillMenu.jsx", error: String((e && e.message) || e) }); }

// components/controls/SearchField.jsx
try { (() => {
/** Every search: a filled pill with the magnifier, and a clear button once there's text. */
function SearchField({
  value = '',
  onChange,
  placeholder = 'Search',
  style
}) {
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      padding: '8px 12px',
      borderRadius: 999,
      background: 'var(--surface-card)',
      color: 'var(--text-secondary)',
      ...style
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "magnifyingglass",
    size: 13
  }), /*#__PURE__*/React.createElement("input", {
    value: value,
    placeholder: placeholder,
    "aria-label": placeholder,
    onChange: e => onChange && onChange(e.target.value),
    style: {
      flex: 1,
      minWidth: 0,
      border: 'none',
      outline: 'none',
      background: 'none',
      padding: 0,
      color: 'var(--text-primary)',
      font: '400 13px/16px var(--font-sans)'
    }
  }), value ? /*#__PURE__*/React.createElement("button", {
    type: "button",
    "aria-label": "Clear search",
    onClick: () => onChange && onChange(''),
    style: {
      border: 'none',
      background: 'none',
      padding: 0,
      display: 'flex',
      color: 'var(--text-secondary)',
      cursor: 'pointer'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "xmark.circle.fill",
    size: 13
  })) : null);
}
Object.assign(__ds_scope, { SearchField });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/controls/SearchField.jsx", error: String((e && e.message) || e) }); }

// components/data/Amount.jsx
try { (() => {
// Formatting shared by the figure components (UpOnlyFormat).
function compactFigure(v) {
  const m = Math.abs(v);
  if (!(m >= 1e6)) return null;
  const [d, s] = m >= 1e12 ? [1e12, 'T'] : m >= 1e9 ? [1e9, 'B'] : [1e6, 'M'];
  const x = m / d,
    digits = x >= 100 ? 0 : x >= 10 ? 1 : 2;
  return (+x.toFixed(digits)).toLocaleString('en-US', {
    maximumFractionDigits: digits
  }) + s;
}
/** "−$3,200.00"; a million or more is "$1.25M". */
function formatExact(v) {
  const c = compactFigure(v),
    sign = v < 0 ? '−' : '';
  return sign + '$' + (c || Math.abs(v).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }));
}
/** "$3,200" whole dollars. */
function formatMoney(v) {
  const c = compactFigure(v),
    sign = v < 0 ? '−' : '';
  return sign + '$' + (c || Math.round(Math.abs(v)).toLocaleString('en-US'));
}
/** "2.1%" — size of a change as a fraction (0.021). */
function formatMagnitude(f) {
  return Math.abs(Math.round(f * 1000) / 10).toFixed(1) + '%';
}
/** "▲ 2.1%" / "▼ 0.4%" / "0.0%". */
function arrowPercent(f) {
  const r = Math.round(f * 1000) / 10;
  return (r > 0 ? '▲ ' : r < 0 ? '▼ ' : '') + formatMagnitude(f);
}
function signedColor(v) {
  return v > 0 ? 'var(--color-gain)' : v < 0 ? 'var(--color-loss)' : 'var(--text-secondary)';
}

/** The headline figure: "$" at 24 pt, the dollars at 40 pt bold with tight tracking, the cents in secondary gray. */
function Amount({
  value = 0,
  cents = true,
  signed = false,
  color = 'var(--text-primary)',
  hidden = false,
  style
}) {
  if (hidden) return /*#__PURE__*/React.createElement("div", {
    style: {
      font: '700 40px/1 var(--font-sans)',
      color: 'var(--text-primary)',
      ...style
    },
    "aria-label": "Hidden value"
  }, "\u2022\u2022\u2022\u2022");
  const sign = value < 0 ? '−' : signed && value > 0 ? '+' : '';
  const short = compactFigure(value);
  let whole = short,
    fraction = '';
  if (!short) {
    const text = Math.abs(value).toLocaleString('en-US', {
      minimumFractionDigits: cents ? 2 : 0,
      maximumFractionDigits: cents ? 2 : 0
    });
    const dot = cents ? text.lastIndexOf('.') : -1;
    whole = dot >= 0 ? text.slice(0, dot) : text;
    fraction = dot >= 0 ? text.slice(dot) : '';
  }
  const digits = {
    font: '700 40px/1 var(--font-sans)',
    letterSpacing: '-1.3px',
    fontVariantNumeric: 'tabular-nums'
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 1,
      color,
      whiteSpace: 'nowrap',
      ...style
    },
    "aria-label": sign + '$' + whole + fraction
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: '700 24px/1 var(--font-sans)'
    }
  }, sign, "$"), /*#__PURE__*/React.createElement("span", {
    style: digits
  }, whole), fraction ? /*#__PURE__*/React.createElement("span", {
    style: {
      ...digits,
      color: 'var(--text-secondary)'
    }
  }, fraction) : null);
}
Object.assign(__ds_scope, { compactFigure, formatExact, formatMoney, formatMagnitude, arrowPercent, signedColor, Amount });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/Amount.jsx", error: String((e && e.message) || e) }); }

// components/charts/LineChart.jsx
try { (() => {
const {
  useLayoutEffect,
  useMemo,
  useRef,
  useState
} = React;
let seq = 0;
function niceTicks(min, max) {
  if (min === max) {
    const pad = Math.abs(max) * 0.05 || 1;
    min -= pad;
    max += pad;
  }
  const raw = (max - min) / 2,
    mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].find(s => s * mag >= raw) * mag;
  const lo = Math.floor(min / step) * step,
    hi = Math.ceil(max / step) * step,
    ticks = [];
  for (let v = lo; v <= hi + step / 2; v += step) ticks.push(v);
  return {
    lo,
    hi,
    ticks
  };
}
function axisLabel(v) {
  const m = Math.abs(v),
    s = v < 0 ? '−$' : '$';
  if (m >= 1e6) return s + +(m / 1e6).toFixed(m >= 1e7 ? 0 : 1) + 'M';
  if (m >= 1e3) return s + +(m / 1e3).toFixed(m >= 1e4 ? 0 : 1) + 'K';
  return s + Math.round(m);
}
/** A line chart with a soft glow under the line, a fading area, faint grid, and a hover card beside the pointer. */
function LineChart({
  points = [],
  tint = 'var(--color-gain)',
  height = 120,
  hidden = false,
  formatValue = __ds_scope.formatExact,
  style
}) {
  const box = useRef(null);
  const [width, setWidth] = useState(312);
  const [hover, setHover] = useState(null);
  const [pointerX, setPointerX] = useState(0);
  const id = useMemo(() => 'uoc' + ++seq, []);
  useLayoutEffect(() => {
    if (!box.current) return;
    const ro = new ResizeObserver(e => setWidth(e[0].contentRect.width));
    ro.observe(box.current);
    return () => ro.disconnect();
  }, []);
  const values = points.map(p => p.value).filter(v => v != null);
  if (!values.length) return /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/1 var(--font-sans)',
      color: 'var(--text-secondary)',
      padding: '8px 0'
    }
  }, "No recorded values in this period");
  const {
    lo,
    hi,
    ticks
  } = niceTicks(Math.min(...values), Math.max(...values));
  const labels = ticks.map(t => hidden ? '••••' : axisLabel(t));
  const axisW = Math.max(...labels.map(l => l.length)) * 6 + 9;
  const edge = 6,
    plotW = Math.max(10, width - axisW - edge),
    n = points.length;
  const x = i => n > 1 ? i / (n - 1) * plotW : 12;
  const y = v => 6 + (1 - (v - lo) / (hi - lo)) * (height - 12);
  const pts = points.map((p, i) => p.value == null ? null : [x(i), y(p.value)]);
  let d = '',
    started = false;
  pts.forEach(p => {
    if (!p) return;
    d += (started ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1);
    started = true;
  });
  const real = pts.filter(Boolean);
  const area = d + 'L' + real[real.length - 1][0].toFixed(1) + ' ' + height + 'L' + real[0][0].toFixed(1) + ' ' + height + 'Z';
  const cut = hover != null ? x(hover) : plotW + edge * 2;
  const first = points.findIndex(p => p.value != null);
  const hp = hover != null ? points[hover] : null;
  const change = hp && hp.value != null && points[first].value ? hp.value / points[first].value - 1 : null;
  const onMove = e => {
    const r = e.currentTarget.getBoundingClientRect(),
      lx = e.clientX - r.left - axisW;
    setPointerX(e.clientX - r.left);
    setHover(Math.max(0, Math.min(n - 1, Math.round(lx / plotW * (n - 1)))));
  };
  const cardW = 150,
    cardLeft = pointerX > width / 2 ? Math.max(0, pointerX - cardW - 14) : Math.min(width - cardW, pointerX + 14);
  return /*#__PURE__*/React.createElement("div", {
    ref: box,
    style: {
      position: 'relative',
      width: '100%',
      ...style
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: width,
    height: height + 18,
    style: {
      display: 'block',
      overflow: 'visible'
    },
    onMouseMove: onMove,
    onMouseLeave: () => setHover(null)
  }, /*#__PURE__*/React.createElement("defs", null, /*#__PURE__*/React.createElement("linearGradient", {
    id: id + 'a',
    x1: "0",
    y1: "0",
    x2: "0",
    y2: height,
    gradientUnits: "userSpaceOnUse"
  }, /*#__PURE__*/React.createElement("stop", {
    offset: "0",
    style: {
      stopColor: tint,
      stopOpacity: 0.22
    }
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "1",
    style: {
      stopColor: tint,
      stopOpacity: 0
    }
  })), /*#__PURE__*/React.createElement("linearGradient", {
    id: id + 'b',
    x1: "0",
    y1: "0",
    x2: "0",
    y2: height,
    gradientUnits: "userSpaceOnUse"
  }, /*#__PURE__*/React.createElement("stop", {
    offset: "0",
    style: {
      stopColor: tint,
      stopOpacity: 0.07
    }
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "1",
    style: {
      stopColor: tint,
      stopOpacity: 0
    }
  })), /*#__PURE__*/React.createElement("linearGradient", {
    id: id + 'x',
    x1: "0",
    y1: "0",
    x2: "0",
    y2: height,
    gradientUnits: "userSpaceOnUse"
  }, /*#__PURE__*/React.createElement("stop", {
    offset: "0",
    stopColor: "#fff",
    stopOpacity: "0"
  }), /*#__PURE__*/React.createElement("stop", {
    offset: ".3",
    stopColor: "#fff",
    stopOpacity: ".3"
  }), /*#__PURE__*/React.createElement("stop", {
    offset: ".7",
    stopColor: "#fff",
    stopOpacity: ".3"
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "1",
    stopColor: "#fff",
    stopOpacity: "0"
  })), /*#__PURE__*/React.createElement("filter", {
    id: id + 'g',
    x: "-10%",
    y: "-50%",
    width: "120%",
    height: "200%"
  }, /*#__PURE__*/React.createElement("feGaussianBlur", {
    stdDeviation: "2.5"
  })), /*#__PURE__*/React.createElement("clipPath", {
    id: id + 'u'
  }, /*#__PURE__*/React.createElement("rect", {
    x: -edge,
    y: -edge,
    width: cut + edge,
    height: height + edge * 2
  })), /*#__PURE__*/React.createElement("clipPath", {
    id: id + 'r'
  }, /*#__PURE__*/React.createElement("rect", {
    x: cut,
    y: -edge,
    width: plotW + edge * 2 - cut,
    height: height + edge * 2
  }))), ticks.map((t, i) => /*#__PURE__*/React.createElement("g", {
    key: i
  }, /*#__PURE__*/React.createElement("line", {
    x1: axisW,
    x2: axisW + plotW,
    y1: y(t),
    y2: y(t),
    stroke: "rgba(255,255,255,0.06)"
  }), /*#__PURE__*/React.createElement("text", {
    x: axisW - 7,
    y: y(t),
    dy: "0.35em",
    textAnchor: "end",
    style: {
      font: '400 10px var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      fill: 'rgba(255,255,255,0.45)'
    }
  }, labels[i]))), /*#__PURE__*/React.createElement("g", {
    transform: 'translate(' + axisW + ',0)'
  }, points.map((p, i) => p.axisLabel ? /*#__PURE__*/React.createElement("g", {
    key: 'm' + i
  }, /*#__PURE__*/React.createElement("line", {
    x1: x(i),
    x2: x(i),
    y1: 0,
    y2: height,
    stroke: "rgba(255,255,255,0.05)"
  }), /*#__PURE__*/React.createElement("text", {
    x: x(i),
    y: height + 12,
    textAnchor: "middle",
    style: {
      font: '400 10px var(--font-sans)',
      fill: 'rgba(255,255,255,0.5)'
    }
  }, p.axisLabel)) : null), /*#__PURE__*/React.createElement("g", {
    clipPath: 'url(#' + id + 'u)'
  }, /*#__PURE__*/React.createElement("path", {
    d: area,
    fill: 'url(#' + id + 'a)'
  }), /*#__PURE__*/React.createElement("path", {
    d: d,
    fill: "none",
    style: {
      stroke: tint
    },
    strokeOpacity: "0.5",
    strokeWidth: "3",
    strokeLinecap: "round",
    strokeLinejoin: "round",
    filter: 'url(#' + id + 'g)'
  }), /*#__PURE__*/React.createElement("path", {
    d: d,
    fill: "none",
    style: {
      stroke: tint
    },
    strokeWidth: "2",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  })), hover != null ? /*#__PURE__*/React.createElement("g", {
    clipPath: 'url(#' + id + 'r)'
  }, /*#__PURE__*/React.createElement("path", {
    d: area,
    fill: 'url(#' + id + 'b)'
  }), /*#__PURE__*/React.createElement("path", {
    d: d,
    fill: "none",
    style: {
      stroke: tint
    },
    strokeOpacity: "0.3",
    strokeWidth: "2",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  })) : null, hover != null ? /*#__PURE__*/React.createElement("line", {
    x1: cut,
    x2: cut,
    y1: 0,
    y2: height,
    stroke: 'url(#' + id + 'x)'
  }) : null, hover != null && pts[hover] ? /*#__PURE__*/React.createElement("circle", {
    cx: pts[hover][0],
    cy: pts[hover][1],
    r: "4",
    style: {
      fill: tint
    },
    stroke: "var(--uo-black)",
    strokeWidth: "2"
  }) : null)), hp ? /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 0,
      left: cardLeft,
      width: cardW,
      boxSizing: 'border-box',
      padding: '9px 11px',
      borderRadius: 11,
      pointerEvents: 'none',
      background: 'var(--material-bg)',
      backdropFilter: 'blur(24px) saturate(1.6)',
      WebkitBackdropFilter: 'blur(24px) saturate(1.6)',
      boxShadow: 'var(--material-border), var(--shadow-hover-card)',
      display: 'flex',
      flexDirection: 'column',
      gap: 3
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 10px/1.2 var(--font-sans)',
      color: 'var(--text-secondary)'
    }
  }, hp.detailLabel || hp.label), /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 15px/1.2 var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      color: 'var(--text-primary)',
      whiteSpace: 'nowrap'
    }
  }, hp.value == null ? 'No recorded value' : hidden ? '••••' : formatValue(hp.value)), change != null && hover !== first ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 4,
      font: '500 10px/1.2 var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: __ds_scope.signedColor(Math.round(change * 1000))
    }
  }, __ds_scope.arrowPercent(change)), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-secondary)'
    }
  }, "since ", points[first].label)) : null) : null);
}
Object.assign(__ds_scope, { LineChart });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/charts/LineChart.jsx", error: String((e && e.message) || e) }); }

// components/data/ChangeBadge.jsx
try { (() => {
/** A change as an outlined pill, "↑ 21.0%": green up, red down. */
function ChangeBadge({
  fraction = 0,
  style
}) {
  const r = Math.round(fraction * 1000) / 10;
  const tint = r > 0 ? 'var(--color-gain)' : r < 0 ? 'var(--color-loss)' : 'var(--text-secondary)';
  const rgb = r > 0 ? '58,181,127' : r < 0 ? '255,69,58' : '255,255,255';
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 2,
      padding: '2px 7px',
      borderRadius: 999,
      color: tint,
      whiteSpace: 'nowrap',
      background: 'rgba(' + rgb + ',0.1)',
      boxShadow: 'inset 0 0 0 1px rgba(' + rgb + ',0.75)',
      font: '600 12px/16px var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      ...style
    }
  }, r !== 0 ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: r > 0 ? 'arrow.up' : 'arrow.down',
    size: 11
  }) : null, __ds_scope.formatMagnitude(fraction));
}
Object.assign(__ds_scope, { ChangeBadge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/ChangeBadge.jsx", error: String((e && e.message) || e) }); }

// components/data/HeadlineStats.jsx
try { (() => {
/** The figures under the headline, side by side: "30D ▲ 13.3% +$4,036.90" beside "All-time ▲ 31.2% +$1,310". */
function HeadlineStats({
  stats = [],
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'flex-start',
      gap: 12,
      ...style
    }
  }, stats.map(s => /*#__PURE__*/React.createElement("div", {
    key: s.label,
    style: {
      flex: 1,
      minWidth: 0,
      display: 'flex',
      flexDirection: 'column',
      gap: 2
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/1.2 var(--font-sans)',
      color: 'var(--text-secondary)',
      whiteSpace: 'nowrap'
    }
  }, s.label), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 6,
      whiteSpace: 'nowrap',
      font: '12px/1.2 var(--font-sans)',
      fontVariantNumeric: 'tabular-nums'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontWeight: 600,
      color: s.color || 'var(--text-primary)'
    }
  }, s.value), s.detail ? /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-secondary)'
    }
  }, s.detail) : null))), stats.length === 1 ? /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }) : null);
}
Object.assign(__ds_scope, { HeadlineStats });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/HeadlineStats.jsx", error: String((e && e.message) || e) }); }

// components/data/StatTile.jsx
try { (() => {
/** A figure in its own tile: quiet title, the figure at 16 pt, an optional line under it. Tiles sit two to a row. */
function StatTile({
  title,
  value,
  detail,
  detailColor = 'var(--text-secondary)',
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 4,
      padding: '10px 12px',
      background: 'var(--surface-card)',
      borderRadius: 'var(--radius-card)',
      minWidth: 0,
      boxSizing: 'border-box',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 11px/1.2 var(--font-sans)',
      color: 'var(--text-secondary)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, title), /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 16px/1.2 var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      color: 'var(--text-primary)',
      whiteSpace: 'nowrap'
    }
  }, value), detail ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 11px/1.2 var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      color: detailColor,
      whiteSpace: 'nowrap'
    }
  }, detail) : null);
}
Object.assign(__ds_scope, { StatTile });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/StatTile.jsx", error: String((e && e.message) || e) }); }

// components/data/SymbolBadge.jsx
try { (() => {
/** A symbol on a 16% tint of its colour in a rounded square (radius = size × 0.28). */
function SymbolBadge({
  icon = 'building.columns.fill',
  tint = 'var(--tint-net-worth)',
  size = 28,
  style
}) {
  return /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: 'relative',
      width: size,
      height: size,
      flex: 'none',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      borderRadius: size * 0.28,
      color: tint,
      overflow: 'hidden',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      inset: 0,
      background: tint,
      opacity: 0.16
    }
  }), /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon,
    size: Math.round(size * 0.5),
    style: {
      position: 'relative'
    }
  }));
}
Object.assign(__ds_scope, { SymbolBadge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/SymbolBadge.jsx", error: String((e && e.message) || e) }); }

// components/data/AssetBadge.jsx
try { (() => {
const PALETTE = ['#F2941A', '#617DEB', '#29A88F', '#DB4D5C', '#8C5CDB', '#2199D6', '#D670B3', '#669E3D', '#9E7A4D', '#5C708A'];
const KNOWN = {
  bitcoin: 0,
  ethereum: 1,
  tether: 2,
  'usd-coin': 5,
  solana: 4,
  ripple: 9,
  cardano: 5,
  dogecoin: 8
};
const METALS = {
  gold: '#D4A838',
  silver: '#8C949E',
  platinum: '#738594',
  palladium: '#948070'
};
function colourIndex(id) {
  if (id in KNOWN) return KNOWN[id];
  let h = 0;
  for (const c of id) h = h * 31 + c.codePointAt(0) & 0xFFFF;
  return h % PALETTE.length;
}
/** A coin, bank or metal at a glance: a bundled logo, else the ticker's first letter on a colour fixed by its id, else the metal bar. */
function AssetBadge({
  src,
  shape = 'rounded',
  id = '',
  symbol = '',
  metal,
  size = 28,
  style
}) {
  if (metal) return /*#__PURE__*/React.createElement(__ds_scope.SymbolBadge, {
    icon: "square.stack.3d.up.fill",
    tint: METALS[metal] || METALS.gold,
    size: size,
    style: style
  });
  if (src) return /*#__PURE__*/React.createElement("img", {
    src: src,
    alt: "",
    width: size,
    height: size,
    style: {
      width: size,
      height: size,
      flex: 'none',
      objectFit: shape === 'circle' ? 'contain' : 'cover',
      borderRadius: shape === 'circle' ? '50%' : size * 0.28,
      display: 'block',
      ...style
    }
  });
  const tint = PALETTE[colourIndex(id || symbol)];
  return /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: 'relative',
      width: size,
      height: size,
      flex: 'none',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      borderRadius: size * 0.28,
      overflow: 'hidden',
      color: tint,
      font: '700 ' + Math.round(size * 0.5) + 'px/1 var(--font-rounded)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      inset: 0,
      background: tint,
      opacity: 0.15
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'relative'
    }
  }, id === 'bitcoin' ? '₿' : (symbol || id).slice(0, 1).toUpperCase()));
}
Object.assign(__ds_scope, { AssetBadge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/AssetBadge.jsx", error: String((e && e.message) || e) }); }

// components/data/ValueRow.jsx
try { (() => {
/** A label and a value on one line: label secondary on the left, value primary with tabular digits on the right. */
function ValueRow({
  label,
  value,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 8,
      minHeight: 28,
      font: '400 13px/28px var(--font-sans)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-secondary)'
    }
  }, label), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-primary)',
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, value));
}
Object.assign(__ds_scope, { ValueRow });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/ValueRow.jsx", error: String((e && e.message) || e) }); }

// components/lists/HoldingRow.jsx
try { (() => {
const {
  useState
} = React;
const COL = 96;
/** Column heads of a portfolio's holdings table: Asset │ Price │ Value ⌄ (the value head picks the order). */
function HoldingsHeader({
  sort = 'Value',
  onSort,
  style
}) {
  const cell = {
    font: '400 11px/14px var(--font-sans)',
    color: 'var(--text-secondary)'
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 8,
      paddingBottom: 2,
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      flex: 1
    }
  }, "Asset"), /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      width: COL,
      textAlign: 'right'
    }
  }, "Price"), /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: onSort,
    style: {
      ...cell,
      width: COL,
      display: 'flex',
      justifyContent: 'flex-end',
      alignItems: 'center',
      gap: 3,
      border: 'none',
      background: 'none',
      padding: 0,
      cursor: 'pointer'
    }
  }, sort, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron.down",
    size: 9
  })));
}
/** One holding: asset and quantity │ price and its move │ value. */
function HoldingRow({
  ticker,
  quantity,
  price,
  change,
  value,
  badge,
  onClick,
  style
}) {
  const [hover, setHover] = useState(false);
  return /*#__PURE__*/React.createElement("div", {
    role: onClick ? 'button' : undefined,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      position: 'relative',
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      padding: '8px 0',
      cursor: onClick ? 'pointer' : 'default',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: 3,
      bottom: 3,
      left: -7,
      right: -7,
      borderRadius: 8,
      background: hover && onClick ? 'var(--surface-row-hover)' : 'transparent'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      flex: 1,
      minWidth: 0,
      display: 'flex',
      alignItems: 'center',
      gap: 10
    }
  }, badge, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 2,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 13px/16px var(--font-sans)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, ticker), quantity ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/14px var(--font-sans)',
      color: 'var(--text-secondary)',
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, quantity) : null)), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      width: COL,
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'flex-end',
      gap: 2,
      fontVariantNumeric: 'tabular-nums'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 13px/16px var(--font-sans)',
      whiteSpace: 'nowrap'
    }
  }, price || '—'), change != null ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 11px/14px var(--font-sans)',
      color: __ds_scope.signedColor(Math.round(change * 1000))
    }
  }, __ds_scope.arrowPercent(change)) : null), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      width: COL,
      textAlign: 'right',
      font: '600 13px/16px var(--font-sans)',
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, value));
}
Object.assign(__ds_scope, { HoldingsHeader, HoldingRow });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/lists/HoldingRow.jsx", error: String((e && e.message) || e) }); }

// components/lists/Row.jsx
try { (() => {
const {
  useState
} = React;
/** Every list row: badge, name over caption, value over its change, then a chevron or a quiet "…". */
function Row({
  title,
  caption,
  value,
  change,
  valueDetail,
  badge,
  chevron = false,
  selected = false,
  menu,
  onClick,
  style
}) {
  const [hover, setHover] = useState(false);
  const [down, setDown] = useState(false);
  const figure = value != null && /\d/.test(value);
  const fill = down || selected ? 'var(--surface-row-selected)' : hover && onClick ? 'var(--surface-row-hover)' : 'transparent';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 6,
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    role: onClick ? 'button' : undefined,
    tabIndex: onClick ? 0 : undefined,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setDown(false);
    },
    onMouseDown: () => setDown(true),
    onMouseUp: () => setDown(false),
    style: {
      position: 'relative',
      flex: 1,
      minWidth: 0,
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      minHeight: 30,
      padding: '8px 0',
      cursor: onClick ? 'pointer' : 'default'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: 3,
      bottom: 3,
      left: -7,
      right: -7,
      borderRadius: 8,
      background: fill,
      transition: 'background 120ms'
    }
  }), badge ? /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'relative',
      display: 'flex'
    }
  }, badge) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      flex: 1,
      minWidth: 100,
      display: 'flex',
      flexDirection: 'column',
      gap: 1
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 13px/16px var(--font-sans)',
      color: 'var(--text-primary)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, title), caption ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/14px var(--font-sans)',
      color: 'var(--text-secondary)'
    }
  }, caption) : null), value != null ? /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'flex-end',
      gap: 1,
      flex: 'none'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: figure ? '600 13px/16px var(--font-sans)' : '400 12px/16px var(--font-sans)',
      color: figure ? 'var(--text-primary)' : 'var(--text-secondary)',
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, value), change != null ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 11px/14px var(--font-sans)',
      color: __ds_scope.signedColor(Math.round(change * 1000)),
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, __ds_scope.arrowPercent(change)) : valueDetail ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/14px var(--font-sans)',
      color: 'var(--text-secondary)',
      fontVariantNumeric: 'tabular-nums',
      whiteSpace: 'nowrap'
    }
  }, valueDetail) : null) : null, chevron ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron.right",
    size: 10,
    color: "var(--text-tertiary)",
    style: {
      position: 'relative'
    }
  }) : null), menu || null);
}
/** The quiet "…" at the end of a row. */
function RowMenu({
  label = 'Options',
  onClick
}) {
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    "aria-label": label,
    onClick: onClick,
    style: {
      width: 22,
      height: 22,
      border: 'none',
      background: 'none',
      padding: 0,
      cursor: 'pointer',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      color: 'var(--text-secondary)',
      flex: 'none'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "ellipsis",
    size: 13
  }));
}
Object.assign(__ds_scope, { Row, RowMenu });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/lists/Row.jsx", error: String((e && e.message) || e) }); }

// components/lists/SourceRow.jsx
try { (() => {
/** One data source: what it is, a status dot and line, and its switch. */
function SourceRow({
  title,
  icon = 'arrow.triangle.2.circlepath',
  tint = 'var(--tint-net-worth)',
  status = 'Off',
  statusColor = 'rgba(255,255,255,0.28)',
  on = false,
  onChange,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      padding: '9px 0',
      ...style
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.SymbolBadge, {
    icon: icon,
    tint: tint,
    size: 28
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0,
      display: 'flex',
      flexDirection: 'column',
      gap: 2
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '500 13px/16px var(--font-sans)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, title), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 5
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 6,
      height: 6,
      borderRadius: '50%',
      background: statusColor,
      flex: 'none'
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: '400 11px/14px var(--font-sans)',
      color: 'var(--text-secondary)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, status))), /*#__PURE__*/React.createElement(__ds_scope.Switch, {
    on: on,
    onChange: onChange,
    label: title
  }));
}
Object.assign(__ds_scope, { SourceRow });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/lists/SourceRow.jsx", error: String((e && e.message) || e) }); }

// components/navigation/PageHeader.jsx
try { (() => {
/** A page's header: round Back on the left, the title centred, the page's own actions on the right. Both sides are 72 pt so the title stays centred. */
function PageHeader({
  title,
  subtitle,
  back = 'back',
  onBack,
  trailing,
  style
}) {
  const icon = back === 'cancel' ? 'xmark' : back === 'done' ? 'checkmark' : 'chevron.left';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      minHeight: 32,
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 72,
      flex: 'none'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.CircleButton, {
    icon: icon,
    label: back === 'cancel' ? 'Cancel' : back === 'done' ? 'Done' : 'Back',
    onClick: onBack
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0,
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: 1,
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 17px/1.2 var(--font-sans)',
      color: 'var(--text-primary)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      maxWidth: '100%'
    }
  }, title), subtitle ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/1.3 var(--font-sans)',
      color: 'var(--text-secondary)'
    }
  }, subtitle) : null), /*#__PURE__*/React.createElement("div", {
    style: {
      minWidth: 72,
      flex: 'none',
      display: 'flex',
      justifyContent: 'flex-end',
      gap: 8
    }
  }, trailing));
}
Object.assign(__ds_scope, { PageHeader });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/navigation/PageHeader.jsx", error: String((e && e.message) || e) }); }

// components/navigation/SetupHeader.jsx
try { (() => {
/** Setup's header: brand mark, "Step 2 of 2" in the step's tint, progress capsules, a 22 pt title and a line under it. */
function SetupHeader({
  step = 1,
  total = 2,
  icon = 'arrow.triangle.2.circlepath',
  tint = 'var(--tint-net-worth)',
  title,
  subtitle,
  mark,
  style
}) {
  const dots = [];
  for (let v = 1; v <= total; v++) dots.push(/*#__PURE__*/React.createElement("span", {
    key: v,
    style: {
      width: v === step ? 18 : 6,
      height: 6,
      borderRadius: 999,
      background: v === step ? tint : 'rgba(255,255,255,0.11)'
    }
  }));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8
    }
  }, mark || null, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 4,
      color: tint,
      font: '500 11px/1 var(--font-sans)'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon,
    size: 11
  }), "Step ", step, " of ", total), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      display: 'flex',
      gap: 5
    }
  }, dots)), /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 22px/1.2 var(--font-sans)',
      letterSpacing: '-0.4px',
      color: 'var(--text-primary)',
      textWrap: 'pretty'
    }
  }, title), subtitle ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 12px/1.4 var(--font-sans)',
      color: 'var(--text-secondary)',
      textWrap: 'pretty'
    }
  }, subtitle) : null);
}
Object.assign(__ds_scope, { SetupHeader });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/navigation/SetupHeader.jsx", error: String((e && e.message) || e) }); }

// components/navigation/SwitcherTitle.jsx
try { (() => {
/** The dashboard's title is the switcher: the page's name at 20 pt bold with a quiet chevron that turns over while open. */
function SwitcherTitle({
  title = 'All assets',
  owner,
  open = false,
  onClick,
  style
}) {
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: onClick,
    style: {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'flex-start',
      border: 'none',
      background: 'none',
      padding: 0,
      cursor: 'pointer',
      color: 'var(--text-primary)',
      minWidth: 0,
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 6,
      maxWidth: '100%'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: '700 20px/1.2 var(--font-sans)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, title), /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron.down",
    size: 12,
    color: "var(--text-secondary)",
    style: {
      transform: open ? 'rotate(180deg)' : 'none',
      transition: 'transform 200ms var(--ease-snappy)',
      alignSelf: 'center'
    }
  })), owner ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: '500 11px/1.2 var(--font-sans)',
      color: 'var(--text-secondary)'
    }
  }, owner) : null);
}
Object.assign(__ds_scope, { SwitcherTitle });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/navigation/SwitcherTitle.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/AttentionBanner.jsx
try { (() => {
/** The glass capsule that names what needs attention and opens the Needs attention page. */
function AttentionBanner({
  items = [],
  onClick,
  style
}) {
  const text = items.length === 1 ? items[0] : items.length + ' things need attention';
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: onClick,
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      width: '100%',
      padding: '9px 14px',
      border: 'none',
      borderRadius: 999,
      background: 'var(--glass-bg)',
      boxShadow: 'var(--glass-border)',
      backdropFilter: 'var(--glass-blur)',
      WebkitBackdropFilter: 'var(--glass-blur)',
      color: 'var(--text-primary)',
      font: '500 12px/1.2 var(--font-sans)',
      cursor: 'pointer',
      textAlign: 'left',
      boxSizing: 'border-box',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 7,
      height: 7,
      borderRadius: '50%',
      background: 'var(--color-warning)',
      flex: 'none'
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      minWidth: 0,
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap'
    }
  }, text), /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron.right",
    size: 10,
    color: "var(--text-tertiary)"
  }));
}
Object.assign(__ds_scope, { AttentionBanner });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/AttentionBanner.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Backdrop.jsx
try { (() => {
const {
  useEffect,
  useState
} = React;
/** Every page's background: near-black, with the brand green glowing softly down from the top edge. The glow drifts
 *  and breathes on long cycles (9–17 s) and holds still with reduced motion or animate={false}. */
function Backdrop({
  animate = true,
  style
}) {
  const [t, setT] = useState(0);
  useEffect(() => {
    const still = !animate || typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (still) return;
    const start = performance.now();
    const id = setInterval(() => setT((performance.now() - start) / 1000), 50);
    return () => clearInterval(id);
  }, [animate]);
  const wave = p => Math.sin(t * 2 * Math.PI / p);
  const inner = (0.22 + 0.03 * wave(9)).toFixed(3);
  const cx = (50 + 14 * wave(17)).toFixed(2) + '%';
  const cy = Math.round((-0.08 + 0.03 * wave(11)) * 300) + 'px';
  const r = 0.62 + 0.05 * wave(13);
  const glow = 'radial-gradient(' + (r * 100).toFixed(1) + '% ' + Math.round(r * 300) + 'px at ' + cx + ' ' + cy + ', rgba(58,181,127,' + inner + ') 0%, rgba(58,181,127,0.07) 50%, rgba(58,181,127,0) 100%)';
  return /*#__PURE__*/React.createElement("div", {
    "aria-hidden": "true",
    style: {
      position: 'absolute',
      inset: 0,
      background: 'var(--uo-black)',
      pointerEvents: 'none',
      overflow: 'hidden',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      left: 0,
      right: 0,
      top: 0,
      height: 300,
      background: glow
    }
  }));
}
Object.assign(__ds_scope, { Backdrop });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Backdrop.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Card.jsx
try { (() => {
/** Every card and tile: a 7% white fill, 16 pt radius, no outline, no lines inside. */
function Card({
  children,
  variant = 'list',
  padding,
  style
}) {
  const pad = padding != null ? padding : variant === 'list' ? '4px 12px' : variant === 'padded' ? 12 : 0;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: 'var(--surface-card)',
      borderRadius: 'var(--radius-card)',
      padding: pad,
      boxSizing: 'border-box',
      ...style
    }
  }, children);
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Card.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Confirmation.jsx
try { (() => {
/** A confirmation that replaces the page: title, detail, Cancel on the left and the action on the right. */
function Confirmation({
  title,
  detail,
  confirmTitle = 'Delete',
  cancelTitle = 'Cancel',
  onConfirm,
  onCancel,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 16,
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '700 18px/1.25 var(--font-sans)',
      color: 'var(--text-primary)',
      textWrap: 'pretty'
    }
  }, title), detail ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 12px/1.4 var(--font-sans)',
      color: 'var(--text-secondary)',
      textWrap: 'pretty'
    }
  }, detail) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      justifyContent: 'space-between',
      gap: 12
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.PillButton, {
    variant: "secondary",
    onClick: onCancel
  }, cancelTitle), /*#__PURE__*/React.createElement(__ds_scope.PillButton, {
    variant: "secondary",
    onClick: onConfirm
  }, confirmTitle)));
}
Object.assign(__ds_scope, { Confirmation });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Confirmation.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/EmptyState.jsx
try { (() => {
/** Every empty page: a badge, what is missing, one line of help and the action that fills it. */
function EmptyState({
  icon = 'chart.line.uptrend.xyaxis',
  tint = 'var(--tint-net-worth)',
  title,
  detail,
  actionTitle,
  onAction,
  style
}) {
  return /*#__PURE__*/React.createElement(__ds_scope.Card, {
    variant: "padded",
    style: {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'flex-start',
      gap: 10,
      ...style
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.SymbolBadge, {
    icon: icon,
    tint: tint,
    size: 30
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      font: '700 18px/1.2 var(--font-sans)',
      color: 'var(--text-primary)'
    }
  }, title), detail ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 12px/1.4 var(--font-sans)',
      color: 'var(--text-secondary)',
      textWrap: 'pretty'
    }
  }, detail) : null, actionTitle ? /*#__PURE__*/React.createElement(__ds_scope.PillButton, {
    onClick: onAction,
    style: {
      marginTop: 4
    }
  }, actionTitle) : null);
}
Object.assign(__ds_scope, { EmptyState });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/EmptyState.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Notice.jsx
try { (() => {
/** One look for problems: a warning asks for a fix, an error says something failed. */
function Notice({
  children,
  kind = 'warning',
  style
}) {
  const color = kind === 'error' ? 'var(--color-error)' : 'var(--color-warning)';
  return /*#__PURE__*/React.createElement("div", {
    role: kind === 'error' ? 'alert' : 'status',
    style: {
      display: 'flex',
      alignItems: 'flex-start',
      gap: 6,
      color,
      font: '400 12px/1.35 var(--font-sans)',
      ...style
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: kind === 'error' ? 'xmark.octagon' : 'exclamationmark.triangle',
    size: 13,
    style: {
      marginTop: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      textWrap: 'pretty'
    }
  }, children));
}
Object.assign(__ds_scope, { Notice });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Notice.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Panel.jsx
try { (() => {
/** The menu-bar panel: 344 pt wide, up to 600 pt tall; the header stays pinned while the page scrolls under it. */
function Panel({
  header,
  children,
  height,
  maxHeight = 600,
  width = 344,
  animateBackdrop = true,
  chrome = true,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      width,
      height,
      maxHeight,
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
      isolation: 'isolate',
      borderRadius: chrome ? 22 : 0,
      boxShadow: chrome ? '0 0 0 0.5px rgba(255,255,255,0.14), 0 24px 60px rgba(0,0,0,0.55)' : 'none',
      color: 'var(--text-primary)',
      fontFamily: 'var(--font-sans)',
      ...style
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Backdrop, {
    animate: animateBackdrop
  }), header ? /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 2,
      flex: 'none',
      padding: '14px 16px 16px'
    }
  }, header) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 1,
      flex: 1,
      minHeight: 0,
      overflowY: 'auto',
      padding: header ? '0 16px 16px' : 16,
      scrollbarWidth: 'none'
    }
  }, children));
}
Object.assign(__ds_scope, { Panel });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Panel.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/AddPage.jsx
try { (() => {
// Add: one list in the home style, what you have, then what came in and went out.
function AddPage({
  ctx
}) {
  const {
    PageHeader,
    Card,
    Row,
    SymbolBadge
  } = window.UpOnlyDesignSystem_ed44c6;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 16
    }
  }, /*#__PURE__*/React.createElement(PageHeader, {
    title: "Add",
    onBack: () => ctx.go('home')
  }), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: "Bank balance",
    caption: "What\u2019s in an account, as of a date",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "building.columns.fill",
      tint: "var(--tint-banks)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Crypto",
    caption: "Coins you hold, by quantity",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "bitcoinsign.circle.fill",
      tint: "var(--tint-crypto)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Metals",
    caption: "Bars and coins, by weight",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "square.stack.3d.up.fill",
      tint: "var(--tint-metals)"
    })
  })), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: "Transaction",
    caption: "Spending or income, typed in",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "arrow.up.arrow.down.circle.fill",
      tint: "var(--tint-cash-flow)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Bank statement",
    caption: "Import transactions from a CSV file",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "doc.text.fill",
      tint: "var(--tint-cash-flow)"
    })
  })), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: "Several at once",
    caption: "Paste a spreadsheet, or update everything you track",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "tablecells",
      tint: "var(--tint-net-worth)"
    })
  })));
}
Object.assign(window, {
  AddPage
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/AddPage.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/App.jsx
try { (() => {
// Click-through of the menu-bar panel: dashboard, switcher, portfolio pages, Add, Manage and Settings.
function App() {
  const {
    Panel,
    AttentionBanner
  } = window.UpOnlyDesignSystem_ed44c6;
  const U = window.UO;
  const saved = (() => {
    try {
      return JSON.parse(localStorage.getItem('uo-kit') || '{}');
    } catch (e) {
      return {};
    }
  })();
  const [page, setPage] = React.useState(saved.page || 'home');
  const [range, setRange] = React.useState(saved.range || '30D');
  const [privacy, setPrivacy] = React.useState(!!saved.privacy);
  React.useEffect(() => {
    localStorage.setItem('uo-kit', JSON.stringify({
      page,
      range,
      privacy
    }));
  }, [page, range, privacy]);
  React.useEffect(() => {
    const k = e => {
      if (e.key === 'Escape') setPage(p => p === 'settings' ? 'manage' : 'home');
      if (e.key === 'p' && e.metaKey && e.shiftKey) {
        e.preventDefault();
        setPrivacy(v => !v);
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);
  const seeds = {
    home: 7,
    switcher: 7,
    crypto: 11,
    metals: 23
  };
  const ctx = {
    page,
    go: setPage,
    range,
    setRange,
    privacy,
    togglePrivacy: () => setPrivacy(!privacy),
    f: privacy ? U.standIn : 1,
    points: end => U.series(range, end, (seeds[page] || 7) * 97 + range.length)
  };
  const dash = {
    home: ['All assets'],
    switcher: ['All assets'],
    crypto: ['Crypto', null, 'All assets'],
    metals: ['Safe', null, 'All assets']
  }[page];
  const header = dash ? /*#__PURE__*/React.createElement(DashboardHeader, {
    ctx: ctx,
    title: dash[0],
    owner: dash[1],
    back: dash[2]
  }) : null;
  let body;
  if (page === 'home') body = /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(AttentionBanner, {
    items: ['Balance needed for Everyday'],
    onClick: () => setPage('manage'),
    style: {
      marginBottom: 16
    }
  }), /*#__PURE__*/React.createElement(HomePage, {
    ctx: ctx
  }));else if (page === 'switcher') body = /*#__PURE__*/React.createElement(SwitcherPage, {
    ctx: ctx
  });else if (page === 'crypto' || page === 'metals') body = /*#__PURE__*/React.createElement(PortfolioPage, {
    key: page,
    ctx: ctx,
    kind: page
  });else if (page === 'add') body = /*#__PURE__*/React.createElement(AddPage, {
    ctx: ctx
  });else if (page === 'manage') body = /*#__PURE__*/React.createElement(ManagePage, {
    ctx: ctx
  });else body = /*#__PURE__*/React.createElement(SettingsPage, {
    ctx: ctx
  });
  return /*#__PURE__*/React.createElement(Panel, {
    header: header,
    height: 600
  }, body);
}
Object.assign(window, {
  App
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/App.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/Header.jsx
try { (() => {
// The dashboard's pinned title row: optional Back, the switcher title, then the eye, + and "…".
function DashboardHeader({
  ctx,
  title,
  owner,
  back
}) {
  const {
    CircleButton,
    PrivacyButton,
    SwitcherTitle
  } = window.UpOnlyDesignSystem_ed44c6;
  const [menu, setMenu] = React.useState(false);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 4,
      minHeight: 32,
      position: 'relative'
    }
  }, back ? /*#__PURE__*/React.createElement(CircleButton, {
    icon: "chevron.left",
    label: 'Back to ' + back,
    onClick: () => ctx.go('home'),
    style: {
      marginRight: 6
    }
  }) : null, /*#__PURE__*/React.createElement(SwitcherTitle, {
    title: title,
    owner: owner,
    open: ctx.page === 'switcher',
    onClick: () => ctx.go(ctx.page === 'switcher' ? 'home' : 'switcher')
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 8
    }
  }, /*#__PURE__*/React.createElement(PrivacyButton, {
    on: ctx.privacy,
    onToggle: ctx.togglePrivacy
  }), /*#__PURE__*/React.createElement(CircleButton, {
    icon: "plus",
    label: "Add",
    onClick: () => ctx.go('add')
  }), /*#__PURE__*/React.createElement(CircleButton, {
    icon: "ellipsis",
    label: "More",
    onClick: () => setMenu(!menu)
  })), menu ? /*#__PURE__*/React.createElement(NativeMenu, {
    onClose: () => setMenu(false),
    items: [{
      title: 'Manage',
      action: () => ctx.go('manage')
    }, null, {
      title: 'Lock',
      shortcut: '⌘L',
      action: () => ctx.go('home')
    }]
  }) : null);
}
// Stand-in for the system menu the "…" opens.
function NativeMenu({
  items,
  onClose
}) {
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
    onClick: onClose,
    style: {
      position: 'fixed',
      inset: 0,
      zIndex: 10
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      right: 0,
      top: 38,
      zIndex: 11,
      minWidth: 170,
      padding: 5,
      borderRadius: 10,
      background: 'rgba(44,44,48,0.92)',
      backdropFilter: 'blur(30px)',
      WebkitBackdropFilter: 'blur(30px)',
      boxShadow: 'inset 0 0 0 0.5px rgba(255,255,255,0.14), 0 10px 30px rgba(0,0,0,0.5)'
    }
  }, items.map((it, i) => it ? /*#__PURE__*/React.createElement("div", {
    key: i,
    onClick: () => {
      onClose();
      it.action();
    },
    style: {
      display: 'flex',
      justifyContent: 'space-between',
      padding: '4px 9px',
      borderRadius: 5,
      font: '400 13px/18px var(--font-sans)',
      cursor: 'default'
    },
    onMouseEnter: e => e.currentTarget.style.background = 'rgba(58,130,247,0.9)',
    onMouseLeave: e => e.currentTarget.style.background = 'none'
  }, /*#__PURE__*/React.createElement("span", null, it.title), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-secondary)'
    }
  }, it.shortcut || '')) : /*#__PURE__*/React.createElement("div", {
    key: i,
    style: {
      height: 1,
      margin: '5px 9px',
      background: 'rgba(255,255,255,0.1)'
    }
  }))));
}
Object.assign(window, {
  DashboardHeader,
  NativeMenu
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/Header.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/HomePage.jsx
try { (() => {
// All assets: the total, how it moved, the range chart and one row per group.
function WorthTop({
  ctx,
  value,
  change,
  allTime
}) {
  const {
    Amount,
    HeadlineStats,
    Segments,
    LineChart
  } = window.UpOnlyDesignSystem_ed44c6;
  const {
    fmt,
    RANGE_TITLES
  } = window.UO;
  const f = ctx.f;
  const pts = ctx.points(value);
  const first = pts[0].value,
    delta = value - first,
    frac = delta / first;
  const stats = [{
    label: RANGE_TITLES[ctx.range],
    value: fmt.arrow(frac),
    color: fmt.tint(Math.round(frac * 1000)),
    detail: fmt.signed(delta * f)
  }];
  if (allTime) stats.push({
    label: 'All-time',
    value: fmt.arrow(allTime.frac),
    color: fmt.tint(allTime.frac),
    detail: '+' + fmt.money(allTime.gain * f)
  });
  const scaled = pts.map(p => ({
    ...p,
    value: p.value * f
  }));
  return /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement(Amount, {
    value: value * f
  }), /*#__PURE__*/React.createElement(HeadlineStats, {
    stats: stats,
    style: {
      marginTop: 8
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
      marginTop: 18
    }
  }, /*#__PURE__*/React.createElement(Segments, {
    value: ctx.range,
    onChange: ctx.setRange
  }), /*#__PURE__*/React.createElement(LineChart, {
    points: scaled,
    tint: delta >= 0 ? 'var(--color-gain)' : 'var(--color-loss)'
  })));
}
function HomePage({
  ctx
}) {
  const {
    Card,
    Row,
    SymbolBadge,
    AssetBadge
  } = window.UpOnlyDesignSystem_ed44c6;
  const U = window.UO,
    f = ctx.f;
  const ch = k => ({
    '24H': 0.004,
    '7D': 0.018,
    '30D': 0.071,
    '1Y': 0.33,
    All: 0.9
  })[ctx.range] * k;
  return /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement(WorthTop, {
    ctx: ctx,
    value: U.total,
    allTime: {
      frac: 0.312,
      gain: 5260
    }
  }), /*#__PURE__*/React.createElement(Card, {
    style: {
      marginTop: 16
    }
  }, /*#__PURE__*/React.createElement(Row, {
    title: "Personal cash",
    caption: U.banks.length + ' accounts',
    value: U.fmt.exact(U.cash * f),
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "building.columns.fill",
      tint: "var(--tint-banks)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Crypto",
    value: U.fmt.exact(U.cryptoTotal * f),
    change: ch(1),
    chevron: true,
    onClick: () => ctx.go('crypto'),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      src: U.A + 'coins/bitcoin.png',
      shape: "circle"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Safe",
    value: U.fmt.exact(U.metalsTotal * f),
    change: ch(0.3),
    chevron: true,
    onClick: () => ctx.go('metals'),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      metal: "gold"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: U.company.name,
    caption: '50% of ' + U.fmt.exact(U.company.whole * f),
    value: U.fmt.exact(U.company.whole * U.company.share * f),
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "building.2.fill",
      tint: "var(--tint-company)"
    })
  })));
}
Object.assign(window, {
  WorthTop,
  HomePage
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/HomePage.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/ManagePage.jsx
try { (() => {
// Manage: every account, portfolio and metal grouped, then Transactions and Settings.
function ManagePage({
  ctx
}) {
  const {
    PageHeader,
    CircleButton,
    Card,
    Row,
    RowMenu,
    SymbolBadge,
    AssetBadge,
    Icon
  } = window.UpOnlyDesignSystem_ed44c6;
  const U = window.UO,
    f = ctx.f,
    x = U.fmt.exact;
  const group = (t, body) => /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 15px/18px var(--font-sans)'
    }
  }, t), body);
  const sub = (t, total, menu) => /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 6,
      padding: '0 12px',
      font: '12px/16px var(--font-sans)',
      color: 'var(--text-secondary)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontWeight: 500,
      display: 'flex',
      alignItems: 'center',
      gap: 4
    }
  }, t, menu ? /*#__PURE__*/React.createElement(Icon, {
    name: "chevron.down",
    size: 9
  }) : null), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontVariantNumeric: 'tabular-nums',
      paddingRight: 28
    }
  }, x(total * f)));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 22
    }
  }, /*#__PURE__*/React.createElement(PageHeader, {
    title: "Manage",
    onBack: () => ctx.go('home'),
    trailing: /*#__PURE__*/React.createElement(CircleButton, {
      icon: "plus",
      label: "Add",
      onClick: () => ctx.go('add')
    })
  }), group('Bank accounts', /*#__PURE__*/React.createElement(React.Fragment, null, sub('Personal', U.cash), /*#__PURE__*/React.createElement(Card, null, U.banks.map(b => /*#__PURE__*/React.createElement(Row, {
    key: b.id,
    title: b.name,
    caption: b.bank,
    value: x(b.value * f),
    valueDetail: b.detail,
    onClick: () => {},
    menu: /*#__PURE__*/React.createElement(RowMenu, {
      label: b.name + ' options'
    }),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      src: b.logo
    })
  }))))), group('Crypto', /*#__PURE__*/React.createElement(React.Fragment, null, sub('Crypto', U.cryptoTotal, true), /*#__PURE__*/React.createElement(Card, null, U.crypto.map(c => /*#__PURE__*/React.createElement(Row, {
    key: c.id,
    title: c.name,
    caption: U.fmt.qty(c.qty * f, c.ticker),
    value: x(c.qty * c.price * f),
    onClick: () => {},
    menu: /*#__PURE__*/React.createElement(RowMenu, {
      label: c.name + ' options'
    }),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      src: c.logo,
      shape: "circle"
    })
  }))))), group('Metals', /*#__PURE__*/React.createElement(React.Fragment, null, sub('Safe', U.metalsTotal, true), /*#__PURE__*/React.createElement(Card, null, U.metals.map(m => /*#__PURE__*/React.createElement(Row, {
    key: m.id,
    title: m.ticker,
    caption: U.fmt.qty(m.qty * f, 'ozt'),
    value: x(m.qty * m.price * f),
    onClick: () => {},
    menu: /*#__PURE__*/React.createElement(RowMenu, {
      label: m.ticker + ' options'
    }),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      metal: m.metal
    })
  }))))), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: "Transactions",
    caption: "214 transactions",
    chevron: true,
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "list.bullet.rectangle.fill",
      tint: "var(--tint-cash-flow)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Settings",
    caption: "Crypto, metals and exchange rates on",
    chevron: true,
    onClick: () => ctx.go('settings'),
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "gearshape.fill",
      tint: "var(--tint-net-worth)"
    })
  })));
}
Object.assign(window, {
  ManagePage
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/ManagePage.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/PortfolioPage.jsx
try { (() => {
// A portfolio: its total and chart, then Asset │ Price │ Value.
function PortfolioPage({
  ctx,
  kind
}) {
  const {
    HoldingsHeader,
    HoldingRow,
    AssetBadge
  } = window.UpOnlyDesignSystem_ed44c6;
  const U = window.UO,
    f = ctx.f;
  const items = kind === 'metals' ? U.metals : U.crypto;
  const total = kind === 'metals' ? U.metalsTotal : U.cryptoTotal;
  const [sort, setSort] = React.useState('Value');
  const order = ['Value', 'Change', 'Name'];
  const effective = ctx.privacy && sort === 'Value' ? 'Name' : sort;
  const rows = [...items].sort((a, b) => effective === 'Value' ? b.qty * b.price - a.qty * a.price : effective === 'Change' ? b.change[ctx.range] - a.change[ctx.range] : a.ticker.localeCompare(b.ticker));
  return /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement(WorthTop, {
    ctx: ctx,
    value: total,
    allTime: kind === 'metals' ? {
      frac: 0.188,
      gain: 968
    } : {
      frac: 0.412,
      gain: 2604
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 16
    }
  }, /*#__PURE__*/React.createElement(HoldingsHeader, {
    sort: effective,
    onSort: () => setSort(order[(order.indexOf(sort) + 1) % 3])
  }), rows.map(h => /*#__PURE__*/React.createElement(HoldingRow, {
    key: h.id,
    ticker: h.ticker,
    quantity: U.fmt.qty(h.qty * f, h.unit || h.ticker),
    price: U.fmt.exact(h.price),
    change: h.change[ctx.range],
    value: U.fmt.exact(h.qty * h.price * f),
    onClick: () => {},
    badge: h.metal ? /*#__PURE__*/React.createElement(AssetBadge, {
      metal: h.metal
    }) : /*#__PURE__*/React.createElement(AssetBadge, {
      src: h.logo,
      shape: "circle"
    })
  }))));
}
Object.assign(window, {
  PortfolioPage
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/PortfolioPage.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/SettingsPage.jsx
try { (() => {
// Settings: where prices and rates come from. Switches save on their own.
function SettingsPage({
  ctx
}) {
  const {
    PageHeader,
    Card,
    SourceRow,
    PillButton,
    Notice
  } = window.UpOnlyDesignSystem_ed44c6;
  const [on, setOn] = React.useState({
    crypto: true,
    metals: true,
    fx: true
  });
  const [busy, setBusy] = React.useState(false);
  const [saved, setSaved] = React.useState(false);
  const set = k => v => {
    setOn({
      ...on,
      [k]: v
    });
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };
  const st = (k, text, stale) => on[k] ? busy ? ['Updating…', 'var(--text-secondary)'] : [text, stale ? 'var(--color-warning)' : 'var(--color-gain)'] : ['Off', 'rgba(255,255,255,0.28)'];
  const rows = [['crypto', 'Crypto prices', 'bitcoinsign.circle.fill', 'var(--tint-crypto)', 'Updated 4 minutes ago'], ['metals', 'Gold & silver prices', 'square.stack.3d.up.fill', 'var(--tint-metals)', 'Updated 38 minutes ago'], ['fx', 'Exchange rates', 'arrow.triangle.2.circlepath', 'var(--tint-net-worth)', 'Updated 5 hours ago', true]];
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 22
    }
  }, /*#__PURE__*/React.createElement(PageHeader, {
    title: "Settings",
    onBack: () => ctx.go('manage')
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 15px/18px var(--font-sans)'
    }
  }, "Data sources"), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 12
    }
  }, /*#__PURE__*/React.createElement(Card, null, rows.map(([k, t, i, c, s, stale]) => {
    const [text, color] = st(k, s, stale);
    return /*#__PURE__*/React.createElement(SourceRow, {
      key: k,
      title: t,
      icon: i,
      tint: c,
      on: on[k],
      onChange: set(k),
      status: text,
      statusColor: color
    });
  })), /*#__PURE__*/React.createElement(PillButton, {
    variant: "secondary",
    size: "large",
    fullWidth: true,
    icon: "arrow.clockwise",
    disabled: busy,
    onClick: () => {
      setBusy(true);
      setTimeout(() => setBusy(false), 1400);
    }
  }, busy ? 'Updating…' : 'Update now'), saved ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 12px/1.4 var(--font-sans)',
      color: 'var(--text-secondary)'
    }
  }, "Changes saved.") : null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '400 11px/1.45 var(--font-sans)',
      color: 'var(--text-secondary)',
      paddingTop: 4,
      textWrap: 'pretty'
    }
  }, "Prices come from Binance, CoinGecko and Gold API, and exchange rates from Frankfurter. They see coin tickers and currency codes, never your amounts."))));
}
Object.assign(window, {
  SettingsPage
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/SettingsPage.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/SwitcherPage.jsx
try { (() => {
// The switcher behind the title: the breakdown, then every page with its value and change.
function SwitcherPage({
  ctx
}) {
  const {
    Card,
    Row,
    SymbolBadge,
    AssetBadge,
    Breakdown
  } = window.UpOnlyDesignSystem_ed44c6;
  const U = window.UO,
    f = ctx.f,
    x = U.fmt.exact;
  const section = t => /*#__PURE__*/React.createElement("div", {
    style: {
      font: '600 13px/16px var(--font-sans)'
    }
  }, t);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 14
    }
  }, /*#__PURE__*/React.createElement(Breakdown, {
    diameter: 100,
    slices: [{
      name: 'Personal cash',
      value: U.cash,
      color: 'var(--tint-banks)'
    }, {
      name: 'Crypto',
      value: U.cryptoTotal,
      color: 'var(--tint-crypto)'
    }, {
      name: 'Metals',
      value: U.metalsTotal,
      color: 'var(--tint-metals)'
    }, {
      name: 'Companies',
      value: U.company.whole * U.company.share,
      color: 'var(--tint-company)'
    }]
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6
    }
  }, section('Your assets'), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: "All assets",
    value: x(U.total * f),
    change: 0.071,
    selected: true,
    onClick: () => ctx.go('home'),
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "square.grid.2x2.fill",
      tint: "var(--tint-net-worth)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Personal cash",
    value: x(U.cash * f),
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "building.columns.fill",
      tint: "var(--tint-banks)"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Crypto",
    value: x(U.cryptoTotal * f),
    change: 0.071,
    onClick: () => ctx.go('crypto'),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      src: U.A + 'coins/bitcoin.png',
      shape: "circle"
    })
  }), /*#__PURE__*/React.createElement(Row, {
    title: "Safe",
    value: x(U.metalsTotal * f),
    change: 0.021,
    onClick: () => ctx.go('metals'),
    badge: /*#__PURE__*/React.createElement(AssetBadge, {
      metal: "gold"
    })
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6
    }
  }, section('Companies'), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: U.company.name,
    caption: '50% of ' + x(U.company.whole * f),
    value: x(U.company.whole * U.company.share * f),
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "building.2.fill",
      tint: "var(--tint-company)"
    })
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6
    }
  }, section('Cash flow'), /*#__PURE__*/React.createElement(Card, null, /*#__PURE__*/React.createElement(Row, {
    title: "Income & spending",
    caption: "This month",
    value: '+' + U.fmt.money(1240 * f),
    onClick: () => {},
    badge: /*#__PURE__*/React.createElement(SymbolBadge, {
      icon: "arrow.up.arrow.down",
      tint: "var(--tint-cash-flow)"
    })
  }))));
}
Object.assign(window, {
  SwitcherPage
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/SwitcherPage.jsx", error: String((e && e.message) || e) }); }

// ui_kits/menu-bar/data.js
try { (() => {
// Fictional sample vault for the UI kit. Today is Sat Sep 26, 2026.
(function () {
  const A = '../../assets/';
  const fmt = {
    exact(v) {
      const m = Math.abs(v),
        s = v < 0 ? '−' : '';
      if (m >= 1e6) return s + '$' + +(m / 1e6).toFixed(2) + 'M';
      return s + '$' + m.toLocaleString('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
      });
    },
    money(v) {
      const s = v < 0 ? '−' : '';
      return s + '$' + Math.round(Math.abs(v)).toLocaleString('en-US');
    },
    signed(v) {
      return (v > 0 ? '+' : '') + fmt.exact(v);
    },
    arrow(f) {
      const r = Math.round(f * 1000) / 10;
      return (r > 0 ? '▲ ' : r < 0 ? '▼ ' : '') + Math.abs(r).toFixed(1) + '%';
    },
    tint(v) {
      return v > 0 ? 'var(--color-gain)' : v < 0 ? 'var(--color-loss)' : 'var(--text-secondary)';
    },
    qty(q, sym) {
      return q.toLocaleString('en-US', {
        maximumFractionDigits: 4,
        minimumFractionDigits: sym === 'ozt' ? 0 : 4
      }) + ' ' + sym;
    }
  };
  const banks = [{
    id: 'everyday',
    name: 'Everyday',
    bank: 'Monzo',
    logo: A + 'banks/monzo.png',
    value: 8420.18
  }, {
    id: 'savings',
    name: 'Savings',
    bank: 'Starling',
    logo: A + 'banks/starling.png',
    value: 12650.0
  }, {
    id: 'usd',
    name: 'USD account',
    bank: 'Wise',
    logo: A + 'banks/wise.png',
    value: 3240.0,
    detail: 'US$3,240.00'
  }];
  const crypto = [{
    id: 'bitcoin',
    ticker: 'BTC',
    name: 'Bitcoin',
    logo: A + 'coins/bitcoin.png',
    qty: 0.101,
    price: 63120,
    change: {
      '24H': 0.008,
      '7D': 0.021,
      '30D': 0.064,
      '1Y': 0.412,
      All: 0.93
    }
  }, {
    id: 'ethereum',
    ticker: 'ETH',
    name: 'Ethereum',
    logo: A + 'coins/ethereum.png',
    qty: 0.84,
    price: 2642.1,
    change: {
      '24H': -0.004,
      '7D': -0.012,
      '30D': 0.031,
      '1Y': 0.118,
      All: 0.41
    }
  }, {
    id: 'solana',
    ticker: 'SOL',
    name: 'Solana',
    logo: A + 'coins/solana.png',
    qty: 2.1,
    price: 146.55,
    change: {
      '24H': 0.017,
      '7D': 0.044,
      '30D': -0.026,
      '1Y': 0.22,
      All: 1.8
    }
  }];
  const metals = [{
    id: 'gold',
    ticker: 'Gold',
    name: 'XAU',
    metal: 'gold',
    qty: 2,
    unit: 'ozt',
    price: 2640,
    change: {
      '24H': 0.002,
      '7D': 0.009,
      '30D': 0.018,
      '1Y': 0.27,
      All: 0.31
    }
  }, {
    id: 'silver',
    ticker: 'Silver',
    name: 'XAG',
    metal: 'silver',
    qty: 30,
    unit: 'ozt',
    price: 28,
    change: {
      '24H': -0.006,
      '7D': 0.004,
      '30D': 0.035,
      '1Y': 0.19,
      All: 0.22
    }
  }];
  const sum = xs => xs.reduce((a, b) => a + b, 0);
  const cash = sum(banks.map(b => b.value));
  const cryptoTotal = sum(crypto.map(c => c.qty * c.price));
  const metalsTotal = sum(metals.map(m => m.qty * m.price));
  const company = {
    name: 'Northwind Studio',
    whole: 17756,
    share: 0.5
  };
  const total = cash + cryptoTotal + metalsTotal + company.whole * company.share;
  // Privacy mode: a fixed per-vault base (6,000–12,000) over the power of ten above the total.
  const standIn = 8340 / Math.pow(10, Math.ceil(Math.log10(total)));
  function rng(seed) {
    let s = seed;
    return () => (s = s * 16807 % 2147483647) / 2147483647;
  }
  const DAY = 86400000,
    now = new Date(2026, 8, 26, 14, 20);
  const wd = d => d.toLocaleDateString('en-US', {
    weekday: 'short'
  });
  const md = d => d.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric'
  });
  const mdy = d => d.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric'
  });
  const RANGES = {
    '24H': {
      n: 97,
      step: 15 * 60000,
      drift: 0.006,
      mark: d => d.getMinutes() === 0 && d.getHours() % 6 === 0 ? d.getHours() === 0 ? wd(d) : d.toLocaleTimeString('en-US', {
        hour: 'numeric'
      }) : null,
      label: d => d.toLocaleTimeString('en-US', {
        hour: 'numeric',
        minute: '2-digit'
      }),
      detail: d => d.toLocaleString('en-US', {
        weekday: 'short',
        hour: 'numeric',
        minute: '2-digit'
      })
    },
    '7D': {
      n: 43,
      step: 4 * 3600000,
      drift: 0.021,
      mark: d => d.getHours() === 0 ? wd(d) : null,
      label: md,
      detail: d => d.toLocaleString('en-US', {
        month: 'short',
        day: 'numeric',
        hour: 'numeric'
      })
    },
    '30D': {
      n: 31,
      step: DAY,
      drift: 0.133,
      mark: d => d.getDay() === 1 ? md(d) : null,
      label: md,
      detail: mdy
    },
    '1Y': {
      n: 53,
      step: 7 * DAY,
      drift: 0.29,
      mark: (d, p) => p && p.getMonth() !== d.getMonth() ? d.getMonth() === 0 ? String(d.getFullYear()) : d.toLocaleDateString('en-US', {
        month: 'short'
      }) : null,
      label: mdy,
      detail: mdy
    },
    All: {
      n: 61,
      step: 14 * DAY,
      drift: 0.62,
      mark: (d, p) => p && p.getFullYear() !== d.getFullYear() ? String(d.getFullYear()) : null,
      label: mdy,
      detail: mdy
    }
  };
  function series(range, end, seed) {
    const R = RANGES[range],
      r = rng(seed),
      start = end / (1 + R.drift),
      pts = [];
    let noise = 0;
    for (let i = 0; i < R.n; i++) {
      const t = i / (R.n - 1);
      noise = noise * 0.7 + (r() - 0.5) * 0.02;
      const d = new Date(now.getTime() - (R.n - 1 - i) * R.step);
      if (range === '24H' || range === '7D') d.setMinutes(Math.round(d.getMinutes() / 15) * 15, 0, 0);
      if (range === '7D') d.setHours(Math.round(d.getHours() / 4) * 4);
      const prev = i > 0 ? new Date(now.getTime() - (R.n - i) * R.step) : null;
      const v = i === R.n - 1 ? end : (start + (end - start) * t) * (1 + noise * (1 - t));
      pts.push({
        label: R.label(d),
        detailLabel: i === R.n - 1 ? 'Now' : R.detail(d),
        value: +v.toFixed(2),
        axisLabel: R.mark(d, prev) || undefined
      });
    }
    return pts;
  }
  window.UO = {
    A,
    fmt,
    banks,
    crypto,
    metals,
    company,
    cash,
    cryptoTotal,
    metalsTotal,
    total,
    standIn,
    series,
    RANGE_TITLES: {
      '24H': 'Past 24 hours',
      '7D': 'Past 7 days',
      '30D': 'Past 30 days',
      '1Y': 'Past year',
      All: 'Since start'
    }
  };
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/menu-bar/data.js", error: String((e && e.message) || e) }); }

__ds_ns.CircleButton = __ds_scope.CircleButton;

__ds_ns.PrivacyButton = __ds_scope.PrivacyButton;

__ds_ns.PillButton = __ds_scope.PillButton;

__ds_ns.PillMenu = __ds_scope.PillMenu;

__ds_ns.Breakdown = __ds_scope.Breakdown;

__ds_ns.LineChart = __ds_scope.LineChart;

__ds_ns.SearchField = __ds_scope.SearchField;

__ds_ns.Segments = __ds_scope.Segments;

__ds_ns.Switch = __ds_scope.Switch;

__ds_ns.ICON_CDN = __ds_scope.ICON_CDN;

__ds_ns.Icon = __ds_scope.Icon;

__ds_ns.Amount = __ds_scope.Amount;

__ds_ns.AssetBadge = __ds_scope.AssetBadge;

__ds_ns.ChangeBadge = __ds_scope.ChangeBadge;

__ds_ns.HeadlineStats = __ds_scope.HeadlineStats;

__ds_ns.StatTile = __ds_scope.StatTile;

__ds_ns.SymbolBadge = __ds_scope.SymbolBadge;

__ds_ns.ValueRow = __ds_scope.ValueRow;

__ds_ns.HoldingsHeader = __ds_scope.HoldingsHeader;

__ds_ns.HoldingRow = __ds_scope.HoldingRow;

__ds_ns.Row = __ds_scope.Row;

__ds_ns.RowMenu = __ds_scope.RowMenu;

__ds_ns.SourceRow = __ds_scope.SourceRow;

__ds_ns.PageHeader = __ds_scope.PageHeader;

__ds_ns.SetupHeader = __ds_scope.SetupHeader;

__ds_ns.SwitcherTitle = __ds_scope.SwitcherTitle;

__ds_ns.AttentionBanner = __ds_scope.AttentionBanner;

__ds_ns.Backdrop = __ds_scope.Backdrop;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.Confirmation = __ds_scope.Confirmation;

__ds_ns.EmptyState = __ds_scope.EmptyState;

__ds_ns.Notice = __ds_scope.Notice;

__ds_ns.Panel = __ds_scope.Panel;

})();

