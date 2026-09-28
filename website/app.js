// The Up website. Ported from the Claude Design file "Up Only Website.dc.html".
// Markup and inline styles are kept as the design wrote them, so a later design change can be copied across section by section.
// The sample figures are fictional: nothing on this page reads a real vault.
(function () {
  'use strict';

  const D = window.UpOnlyDesignSystem_ed44c6;

  // htm hands us the design's HTML-style attributes. Turn them into what React expects:
  // style strings become objects, kebab-case attributes become camelCase, and the design tool's hint-* attributes are dropped.
  const camel = (s) => s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
  const styleCache = new Map();
  function styleObj(s) {
    let o = styleCache.get(s);
    if (o) return o;
    o = {};
    s.split(';').forEach((decl) => {
      const i = decl.indexOf(':');
      if (i < 0) return;
      const k = decl.slice(0, i).trim(), v = decl.slice(i + 1).trim();
      if (!k) return;
      o[k.startsWith('--') ? k : camel(k.replace(/^-webkit-/, 'Webkit-'))] = v;
    });
    styleCache.set(s, o);
    return o;
  }
  function h(type, props, ...children) {
    if (props) {
      const p = {};
      for (const k in props) {
        const v = props[k];
        if (k.startsWith('hint-')) continue;
        if (k === 'style' && typeof v === 'string') p.style = styleObj(v);
        else if (k === 'class') p.className = v;
        else if (typeof type === 'string' && k.includes('-') && !k.startsWith('data-') && !k.startsWith('aria-')) p[camel(k)] = v;
        else p[k] = v;
      }
      props = p;
    }
    return React.createElement(type, props, ...children);
  }
  const html = htm.bind(h);

  // Keyboard support for the div-based switch and buttons.
  const onKeys = (fn) => (ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); fn(ev); } };

  const reducedMotion = !!(window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches);

  class Site extends React.Component {
    state = { privacy: false, range: 'All', heroRange: '1Y', phoneRange: 'All', heroT: 0, donut: false, email: '', emailErr: false, waitDone: false, pv: null, who: 'Founders' };
    rootRef = React.createRef();
    emailRef = React.createRef();
    motion = !reducedMotion;
    TOTAL = 1364273.03;
    F = 0.000834;
    cache = {};

    goWaitlist = () => {
      const el = document.getElementById('iphone');
      if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - 48, behavior: 'smooth' });
      setTimeout(() => this.emailRef.current && this.emailRef.current.focus({ preventScroll: true }), 800);
    };
    goDownload = () => {
      const el = document.getElementById('download');
      if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - 52, behavior: 'smooth' });
    };
    submitWaitlist = (e) => {
      if (e && e.preventDefault) e.preventDefault();
      const ok = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.state.email.trim());
      this.setState(ok ? { waitDone: true, emailErr: false } : { emailErr: true });
    };

    rng(seed) { let s = seed; return () => (s = (s * 16807) % 2147483647) / 2147483647; }
    base(range, seed) {
      const key = range + seed;
      if (this.cache[key]) return this.cache[key];
      const DAY = 864e5, now = new Date(2026, 8, 26, 14, 20);
      const wd = (d) => d.toLocaleDateString('en-US', { weekday: 'short' });
      const md = (d) => d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
      const mdy = (d) => d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
      const tm = (d) => d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
      const R = {
        '24H': { n: 97, step: 9e5, drift: 0.006, mark: (d) => (d.getMinutes() === 0 && d.getHours() % 6 === 0 ? d.toLocaleTimeString('en-US', { hour: 'numeric' }) : null), label: tm },
        '7D': { n: 43, step: 144e5, drift: 0.021, mark: (d, p) => (p && p.getDate() !== d.getDate() ? wd(d) : null), label: md },
        '30D': { n: 31, step: DAY, drift: 0.071, mark: (d) => (d.getDay() === 1 ? md(d) : null), label: md },
        '1Y': { n: 53, step: 7 * DAY, drift: 0.29, mark: (d, p) => (p && p.getMonth() !== d.getMonth() && d.getMonth() % 3 === 0 ? d.toLocaleDateString('en-US', { month: 'short' }) : null), label: mdy },
        All: { n: 61, step: 14 * DAY, drift: 0.62, mark: (d, p) => (p && p.getFullYear() !== d.getFullYear() ? String(d.getFullYear()) : null), label: mdy },
      }[range];
      const dense = seed === 7 ? 5 : 1; R.n = (R.n - 1) * dense + 1; R.step = R.step / dense;
      const r = this.rng(seed * 97 + range.length * 13), end = this.TOTAL, start = end / (1 + R.drift), pts = [];
      let noise = 0;
      for (let i = 0; i < R.n; i++) {
        const t = i / (R.n - 1);
        noise = noise * (dense > 1 ? 0.9 : 0.86) + (r() - 0.5) * (dense > 1 ? 0.055 : 0.009) + (dense > 1 && r() > 0.97 ? (r() - 0.45) * 0.09 : 0);
        const d = new Date(now.getTime() - (R.n - 1 - i) * R.step);
        const p = i > 0 ? new Date(now.getTime() - (R.n - i) * R.step) : null;
        const long = range === 'All' || range === '1Y';
        const amp = dense > 1 ? 3.4 : 1; const wave = (Math.sin(t * Math.PI * 3.3 + seed) * 0.02 * (1 - t) + Math.sin(t * Math.PI * 11 + seed * 2) * 0.005) * amp;
        const dip = long ? -0.06 * Math.exp(-Math.pow((t - 0.58) / 0.06, 2)) : 0;
        let v;
        if (dense > 1) {
          const K = long ? [[0, .56], [.12, .62], [.22, .74], [.3, .92], [.36, 1.12], [.4, .86], [.46, .95], [.55, .9], [.62, 1.02], [.7, .84], [.78, .8], [.86, .9], [.93, .96], [1, 1]]
            : [[0, .9], [.18, .95], [.3, .88], [.45, 1.03], [.55, .94], [.7, .97], [.82, .91], [1, 1]];
          let j = 0; while (j < K.length - 2 && t > K[j + 1][0]) j++;
          const u = (t - K[j][0]) / (K[j + 1][0] - K[j][0]), sm = u * u * (3 - 2 * u);
          const b = K[j][1] + (K[j + 1][1] - K[j][1]) * sm;
          v = i === R.n - 1 ? end : end * b * (1 + noise * 0.9);
        } else v = i === R.n - 1 ? end : (start + (end - start) * Math.pow(t, 1.2)) * (1 + noise * (1 - t * 0.6) + wave + dip);
        pts.push({ label: R.label(d), detailLabel: i === R.n - 1 ? 'Now' : R.label(d), value: +v.toFixed(2), axisLabel: R.mark(d, p) || undefined });
      }
      return (this.cache[key] = pts);
    }
    points(range, seed, f) {
      const key = 's' + range + seed + f;
      if (!this.cache[key]) this.cache[key] = this.base(range, seed).map((p) => ({ ...p, value: +(p.value * f).toFixed(2) }));
      return this.cache[key];
    }
    exact(v) { const m = Math.abs(v), s = v < 0 ? '−' : ''; return s + '$' + m.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
    money(v) { return '$' + Math.round(Math.abs(v)).toLocaleString('en-US'); }
    arrow(fr) { const r = Math.round(fr * 1000) / 10; return (r > 0 ? '▲ ' : r < 0 ? '▼ ' : '') + Math.abs(r).toFixed(1) + '%'; }
    stat(range, seed, f) {
      const pts = this.base(range, seed), a = pts[0].value, b = pts[pts.length - 1].value, fr = (b - a) / a;
      const titles = { '24H': 'Past 24 hours', '7D': 'Past 7 days', '30D': 'Past 30 days', '1Y': 'Past year', All: 'Since start' };
      return { label: titles[range], value: this.arrow(fr), color: fr >= 0 ? 'var(--color-gain)' : 'var(--color-loss)', detail: (b >= a ? '+' : '') + this.exact((b - a) * f) };
    }

    componentDidMount() {
      const t0 = performance.now() + 500, dur = 1700;
      const tick = (now) => {
        const t = this.motion ? Math.min(1, Math.max(0, (now - t0) / dur)) : 1;
        if (t >= 1 || !this._hf || now - this._hf > 32) { this._hf = now; this.setState({ heroT: 1 - Math.pow(1 - t, 4) }); }
        if (t < 1) this.raf = requestAnimationFrame(tick);
      };
      this.raf = requestAnimationFrame(tick);
      setTimeout(() => this.setupMotion(), 60);
      this.onAlign = () => { this.alignPanel(); if (this.drawn) this.placeTip(); };
      window.addEventListener('resize', this.onAlign); setTimeout(this.onAlign, 300); setTimeout(this.onAlign, 1200);
    }
    setupMotion() {
      const root = this.rootRef.current;
      if (!root) return;
      const motion = this.motion;
      const ease = 'cubic-bezier(.22,.7,.2,1)';
      this.io = new IntersectionObserver((entries) => {
        entries.forEach((e) => {
          if (!e.isIntersecting) return;
          const el = e.target;
          if (el.hasAttribute('data-donut')) { this.setState({ donut: true }); this.io.unobserve(el); return; }
          if (el.hasAttribute('data-stagger')) { this.stagger(el); this.io.unobserve(el); return; }
          if (el.hasAttribute('data-ov')) { this.countOv(); this.io.unobserve(el); return; }
          if (el.hasAttribute('data-draw')) { this.drawChart(); this.io.unobserve(el); return; }
          const grid = el.parentElement && getComputedStyle(el.parentElement).display === 'grid' ? [...el.parentElement.children].filter((c) => c.hasAttribute('data-reveal')) : [el];
          if (grid.length > 1) { const top = el.getBoundingClientRect().top; grid.forEach((g) => { if (g === el || Math.abs(g.getBoundingClientRect().top - top) > 40) return; this.io.unobserve(g); g.style.opacity = '1'; g.style.transform = 'none'; }); }
          const d = +(el.getAttribute('data-delay') || 0);
          setTimeout(() => { el.style.opacity = '1'; el.style.transform = 'none'; setTimeout(() => { el.style.removeProperty('transition'); el.style.removeProperty('transform'); el.style.removeProperty('opacity'); el.style.removeProperty('transform-origin'); }, 1300); }, d);
          this.io.unobserve(el);
        });
      }, { threshold: 0.2, rootMargin: '0px 0px -18% 0px' });
      root.querySelectorAll('[data-reveal]').forEach((el) => {
        if (!motion) return;
        const drop = el.getAttribute('data-from') === 'drop';
        el.style.opacity = '0';
        el.style.transform = drop ? 'translateY(-14px) scale(.55)' : 'translateY(28px)';
        if (drop) el.style.transformOrigin = '50% 0';
        el.style.transition = drop ? 'opacity .35s ease, transform .75s cubic-bezier(.34,1.45,.64,1)' : `opacity 1.1s ${ease}, transform 1.1s ${ease}`;
        const r0 = el.getBoundingClientRect(); if (r0.bottom < 0) { el.style.opacity = '1'; el.style.transform = 'none'; return; }
        this.io.observe(el);
      });
      const donut = root.querySelector('[data-donut]');
      if (donut) this.io.observe(donut);
      this.drawEl = root.querySelector('[data-draw]');
      if (motion) root.querySelectorAll('[data-stagger]').forEach((el) => { this.boxes(el).forEach((b) => { b.style.opacity = '0'; b.style.transform = 'translateY(14px)'; }); this.io.observe(el); });
      const ov = root.querySelector('[data-ov]');
      if (motion) {
        if (ov) { this.setState({ ovT: 0 }); this.io.observe(ov); }
        if (this.drawEl) { this.drawEl.style.clipPath = 'inset(-20px 100% -40px 0)'; this.drawn = false; }
      } else {
        this.drawn = true; setTimeout(() => this.placeTip(), 300);
      }
      this.heads = motion ? [...root.querySelectorAll('[data-sh]')] : [];
      if (motion) {
        this.onTile = (e) => { const t = e.target.closest && e.target.closest('[data-tile]'); if (this.lastTile && this.lastTile !== t) { this.lastTile.style.removeProperty('background-image'); } this.lastTile = t; if (!t) return; const r = t.getBoundingClientRect(); t.style.backgroundImage = 'radial-gradient(520px circle at ' + (e.clientX - r.left) + 'px ' + (e.clientY - r.top) + 'px, rgba(255,255,255,.055), rgba(255,255,255,0) 60%)'; };
        this.onTileLeave = () => { if (this.lastTile) this.lastTile.style.removeProperty('background-image'); this.lastTile = null; };
        root.addEventListener('pointermove', this.onTile);
        root.addEventListener('pointerleave', this.onTileLeave);
      }
      this.words = [...root.querySelectorAll('[data-w]')];
      if (motion) this.words.forEach((w) => { w.style.transition = 'opacity .45s ease, transform .5s cubic-bezier(.22,.7,.2,1)'; w.style.display = 'inline-block'; w.style.opacity = '.14'; w.style.transform = 'translateY(4px)'; });
      const hex = '0123456789abcdef';
      this.ciphers = [...root.querySelectorAll('[data-cipher]')];
      if (motion && this.ciphers.length) this.cipherTimer = setInterval(() => {
        for (let n = 0; n < 3; n++) {
          const el = this.ciphers[(Math.random() * this.ciphers.length) | 0], t = el.textContent.split('');
          for (let k = 0; k < 4; k++) { const i = (Math.random() * t.length) | 0; if (t[i] !== ' ') t[i] = hex[(Math.random() * 16) | 0]; }
          el.textContent = t.join('');
        }
      }, 110);
      this.steps = motion ? [...root.querySelectorAll('[data-step]')] : [];
      this.tourEl = root.querySelector('[data-tour]');
      this.tilt = root.querySelector('[data-tilt]');
      this.wordsBox = root.querySelector('[data-words]');
      this.onScroll = () => { if (this.ticking) return; this.ticking = true; requestAnimationFrame(() => { this.ticking = false; this.frame(); }); };
      if (motion) { this.tickTimer = setInterval(() => this.frame(), 500); document.addEventListener('scroll', this.onScroll, { passive: true, capture: true }); window.addEventListener('resize', this.onScroll); this.frame(); }
      else { this.onNav = () => this.navFrame(); document.addEventListener('scroll', this.onNav, { passive: true }); this.navFrame(); }
    }
    alignPanel() {
      const root = this.rootRef.current; if (!root) return;
      const icon = root.querySelector('[data-mb-icon]'), panel = root.querySelector('[data-mb-panel]');
      if (!icon || !panel || !panel.offsetParent) return;
      const box = panel.offsetParent.getBoundingClientRect(), ir = icon.getBoundingClientRect(), s = box.width / panel.offsetParent.offsetWidth || 1;
      const W = panel.offsetParent.offsetWidth, center = (ir.left + ir.width / 2 - box.left) / s, w = panel.offsetWidth;
      // On a phone the mock-up is narrower than the 344pt panel: shrink the panel to fit, pinned under the icon's side.
      const fit = Math.min(1, (W - 16) / w), vw = w * fit, inner = panel.querySelector('[data-mb-fit]');
      if (inner) inner.style.transform = fit < 1 ? 'scale(' + fit.toFixed(4) + ')' : '';
      panel.style.right = Math.min(Math.max(8, W - center - vw / 2), Math.max(8, W - 8 - vw)) + 'px';
    }
    frame() {
      this.alignPanel();
      this.navFrame();
      this.tourFrame();
      const root = this.rootRef.current;
      if (root && (this._sweepT = (this._sweepT || 0) + 1) % 6 === 0) root.querySelectorAll('[data-reveal]').forEach((el) => { if (el.style.opacity === '0' && el.getBoundingClientRect().bottom < 0) { el.style.opacity = '1'; el.style.transform = 'none'; } });
      if (this.heads) { const vh0 = window.innerHeight; this.heads.forEach((el) => { const r = el.getBoundingClientRect(); const p = Math.max(0, Math.min(1, (vh0 * 1.0 - r.top) / (vh0 * 0.28))); const q = 1 - p; el.style.opacity = (0.08 + 0.92 * p).toFixed(3); el.style.transform = q > 0.001 ? 'translateY(' + (q * 36).toFixed(1) + 'px) scale(' + (1 - q * 0.04).toFixed(4) + ')' : 'none'; const f = q > 0.03 ? 'blur(' + (q * 6).toFixed(1) + 'px)' : ''; if (el.style.filter !== f) el.style.filter = f; if (q <= 0.001) { el.style.removeProperty('transform'); el.style.opacity = '1'; } }); }
      if (this.drawEl && !this.drawn) { const r = this.drawEl.getBoundingClientRect(); if (r.top < window.innerHeight * 0.8 && r.bottom > 0) { this.drawn = true; this.drawChart(); } }
      const vh = window.innerHeight, cl = (x) => Math.max(0, Math.min(1, x));
      if (this.tilt) {
        const r = this.tilt.getBoundingClientRect(), p = cl((vh - r.top) / (vh * 0.95));
        this.tilt.style.transform = p >= 1 ? 'none' : `translateY(${((1 - p) * 40).toFixed(1)}px) scale(${(0.92 + 0.08 * p).toFixed(4)})`;
      }
      if (this.wordsBox && this.words.length) {
        const r = this.wordsBox.getBoundingClientRect(), p = cl((vh * 0.78 - r.top) / (r.height + vh * 0.25));
        const lit = Math.round(p * this.words.length);
        this.words.forEach((w, i) => { const on = i < lit; w.style.opacity = on ? '1' : '.14'; w.style.transform = on ? 'none' : 'translateY(4px)'; });
      }
    }
    boxes(el) {
      const out = [];
      const walk = (n) => { for (const c of n.children) { if (getComputedStyle(c).display === 'contents') walk(c); else out.push(c); } };
      walk(el);
      return out.length === 1 && out[0].children.length > 1 ? this.boxes(out[0]) : out;
    }
    stagger(el) {
      this.boxes(el).forEach((b, i) => {
        b.style.transition = 'opacity .7s cubic-bezier(.22,.7,.2,1) ' + (250 + i * 70) + 'ms, transform .7s cubic-bezier(.22,.7,.2,1) ' + (250 + i * 70) + 'ms';
        requestAnimationFrame(() => { b.style.opacity = '1'; b.style.transform = 'none'; });
        setTimeout(() => { b.style.removeProperty('transition'); b.style.removeProperty('transform'); b.style.removeProperty('opacity'); }, 1400 + i * 70);
      });
    }
    navFrame() {
      const root = this.rootRef.current; if (!root) return;
      const bar = root.querySelector('[data-navbar]'); if (bar) { const sc = (document.scrollingElement || document.documentElement).scrollTop || window.scrollY; const on = sc > 8; if (this._navOn !== on) { this._navOn = on; bar.style.boxShadow = on ? 'inset 0 -0.5px 0 rgba(255,255,255,.1)' : 'inset 0 -0.5px 0 rgba(255,255,255,0)'; bar.style.background = on ? 'rgba(9,9,10,.72)' : 'rgba(9,9,10,.6)'; } }
      const vh = window.innerHeight; let cur = null;
      ['why', 'overview', 'privacy', 'iphone'].forEach((id) => { const s = document.getElementById(id); if (s) { const r = s.getBoundingClientRect(); if (r.top < vh * 0.4 && r.bottom > vh * 0.4) cur = id; } });
      if (cur === this._navCur) return; this._navCur = cur;
      root.querySelectorAll('[data-nav]').forEach((a) => { a.style.color = a.getAttribute('data-nav') === cur ? '#fff' : 'rgba(255,255,255,.55)'; });
    }
    tourFrame() {
      if (!this.steps || !this.steps.length || !this.tourEl) return;
      const vh = window.innerHeight, tr = this.tourEl.getBoundingClientRect();
      let act = -1;
      if (tr.top < vh * 0.55 && tr.bottom > vh * 0.45) { let best = 1e9; this.steps.forEach((s, i) => { const r = s.getBoundingClientRect(), d = Math.abs(r.top + r.height / 2 - vh / 2); if (d < best) { best = d; act = i; } }); }
      this.steps.forEach((s, i) => { s.style.opacity = act === -1 || act === i ? '1' : '.3'; });
      if (act === this.tourAct) return;
      const was = this.tourAct; this.tourAct = act;
      const keys = ['vault', 'assets', 'privacy', 'onboard'];
      if (was === 2 && this.tourPriv) { this.tourPriv = false; this.setState({ privacy: false }); }
      if (act === 2) { if (!this.state.privacy) { this.tourPriv = true; this.setState({ privacy: true, pv: null }); } else this.setState({ pv: null }); }
      else this.setState({ pv: act >= 0 ? keys[act] : null });
    }
    // Blurs every visible amount outward from the control that was pressed, then swaps the figures.
    ripple(origin, apply) {
      const root = this.rootRef.current;
      if (!root || !this.motion) { apply(); return; }
      const o = origin && origin.getBoundingClientRect ? origin.getBoundingClientRect() : { left: innerWidth / 2, top: innerHeight / 2, width: 0, height: 0 };
      const ox = o.left + o.width / 2, oy = o.top + o.height / 2, vh = innerHeight;
      const els = [...root.querySelectorAll('span,div')].filter((e) => e.childElementCount === 0 && /^[+−-]?\$|^\$|^\.\d\d$|^[\d,]+(\.\d+)?[KM]?$/.test(e.textContent.trim()) && e.textContent.trim().length > 1).filter((e) => { const r = e.getBoundingClientRect(); return r.bottom > -100 && r.top < vh + 100; });
      els.forEach((e) => {
        const r = e.getBoundingClientRect(), d = Math.hypot(r.left + r.width / 2 - ox, r.top + r.height / 2 - oy), dl = Math.min(520, d * 0.45);
        e.style.transition = 'filter .16s ease ' + dl + 'ms, opacity .16s ease ' + dl + 'ms'; e.style.filter = 'blur(6px)'; e.style.opacity = '.25';
        setTimeout(() => { e.style.transition = 'filter .38s ease, opacity .38s ease'; e.style.filter = ''; e.style.opacity = ''; setTimeout(() => { e.style.removeProperty('transition'); e.style.removeProperty('filter'); e.style.removeProperty('opacity'); }, 420); }, dl + 190);
      });
      setTimeout(apply, 170);
    }
    morphRange(v) {
      const el = this.drawEl;
      if (!el || !this.motion) { this.setState({ range: v }, () => this.placeTip()); return; }
      if (this.tip) this.tip.style.opacity = '0';
      el.style.transformOrigin = '50% 100%';
      el.style.transition = 'opacity .16s ease, transform .16s ease, filter .16s ease';
      el.style.opacity = '0'; el.style.transform = 'scaleY(.9)'; el.style.filter = 'blur(4px)';
      setTimeout(() => {
        this.setState({ range: v });
        requestAnimationFrame(() => {
          el.style.transition = 'opacity .5s ease, transform .6s cubic-bezier(.34,1.3,.64,1), filter .5s ease';
          el.style.opacity = '1'; el.style.transform = 'none'; el.style.filter = 'none';
          setTimeout(() => { ['transition', 'opacity', 'transform', 'filter', 'transform-origin'].forEach((p) => el.style.removeProperty(p)); this.placeTip(); }, 650);
        });
      }, 170);
    }
    // The pulsing dot at the end of the big chart's line.
    placeTip() {
      const el = this.drawEl; if (!el) return;
      const paths = [...el.querySelectorAll('svg path')].filter((p) => p.getAttribute('fill') === 'none' || getComputedStyle(p).fill === 'none');
      const path = paths.sort((a, b) => b.getTotalLength() - a.getTotalLength())[0]; if (!path) return;
      const pt = path.getPointAtLength(path.getTotalLength()), m = path.getScreenCTM(), er = el.getBoundingClientRect();
      if (!m) return;
      const x = pt.x * m.a + pt.y * m.c + m.e - er.left, y = pt.x * m.b + pt.y * m.d + m.f - er.top;
      if (!this.tip) { this.tip = document.createElement('div'); this.tip.setAttribute('aria-hidden', 'true'); Object.assign(this.tip.style, { position: 'absolute', width: '10px', height: '10px', margin: '-5px 0 0 -5px', borderRadius: '5px', background: '#3AB57F', pointerEvents: 'none', transition: 'opacity .4s ease', animation: 'uoPulse 2s ease-out infinite' }); el.appendChild(this.tip); }
      this.tip.style.left = x + 'px'; this.tip.style.top = y + 'px'; this.tip.style.opacity = '1';
    }
    countOv() {
      const t0 = performance.now(), dur = 1600;
      const tick = (now) => {
        const t = Math.min(1, (now - t0) / dur);
        if (t >= 1 || !this._of || now - this._of > 32) { this._of = now; this.setState({ ovT: 1 - Math.pow(1 - t, 4) }); }
        if (t < 1) this.ovRaf = requestAnimationFrame(tick);
      };
      this.ovRaf = requestAnimationFrame(tick);
    }
    drawChart() {
      const el = this.drawEl;
      if (!el) return;
      if (!this.motion) { el.style.removeProperty('clip-path'); return; }
      clearTimeout(this.drawTimer);
      el.style.transition = 'none';
      el.style.clipPath = 'inset(-20px 100% -40px 0)';
      void el.offsetWidth;
      el.style.transition = 'clip-path 1.6s cubic-bezier(.45,.05,.2,1)';
      el.style.clipPath = 'inset(-20px 0% -40px 0)';
      if (this.tip) this.tip.style.opacity = '0';
      this.drawTimer = setTimeout(() => { el.style.removeProperty('clip-path'); el.style.removeProperty('transition'); this.placeTip(); }, 1650);
    }
    componentWillUnmount() {
      cancelAnimationFrame(this.ovRaf); cancelAnimationFrame(this.raf); window.removeEventListener('resize', this.onAlign); clearTimeout(this.drawTimer);
      const root = this.rootRef.current;
      if (root && this.onTile) { root.removeEventListener('pointermove', this.onTile); root.removeEventListener('pointerleave', this.onTileLeave); }
      clearInterval(this.cipherTimer); clearInterval(this.tickTimer);
      if (this.io) this.io.disconnect();
      if (this.onScroll) { document.removeEventListener('scroll', this.onScroll, { capture: true }); window.removeEventListener('resize', this.onScroll); }
      if (this.onNav) document.removeEventListener('scroll', this.onNav);
    }

    togglePrivacy = (e) => {
      const o = (e && e.currentTarget) || document.activeElement;
      this.tourPriv = false;
      this.ripple(o, () => this.setState((s) => ({ privacy: !s.privacy })));
    };

    vals() {
      const e = React.createElement;
      const f = this.state.privacy ? this.F : 1, x = (v) => this.exact(v * f);
      const b = (props) => e(D.AssetBadge, props), sb = (icon, tint) => e(D.SymbolBadge, { icon, tint });
      const { heroRange, range, who, pv, privacy } = this.state;
      const cash = 324310.18, stocks = 543610, crypto = 217952.85, metals = 122400, company = 156000;
      const slices = [
        { name: 'Stocks', value: stocks, color: '#D670B3' },
        { name: 'Cash', value: cash, color: 'var(--tint-banks)' },
        { name: 'Crypto', value: crypto, color: 'var(--tint-crypto)' },
        { name: 'Northwind Studio', value: company, color: 'var(--tint-company)' },
        { name: 'Gold and silver', value: metals, color: 'var(--tint-metals)' },
      ];
      const sliceTotal = slices.reduce((a, s) => a + s.value, 0);

      // The iPhone tour: which overlay the phone shows, and how each step's chip looks.
      const on = (k) => (k === 'privacy' ? privacy : pv === k);
      const tour = {};
      ['vault', 'assets', 'privacy', 'onboard'].forEach((k) => {
        tour[k] = {
          show: k === 'privacy'
            ? () => { const o = document.activeElement; this.tourPriv = false; this.ripple(o, () => this.setState((s) => ({ privacy: !s.privacy, pv: null }))); }
            : () => this.setState((s) => ({ pv: s.pv === k ? null : k })),
          c: on(k) ? '#3AB57F' : 'rgba(255,255,255,.85)',
          bg: on(k) ? 'rgba(58,181,127,.16)' : 'rgba(255,255,255,.1)',
          i: on(k) ? '×' : '+',
          op: pv === k ? 1 : 0,
          tf: pv === k ? 'none' : 'scale(.97)',
        };
      });

      const WHO = {
        Founders: ['Your company, counted at your share.', 'Set your ownership once. Up adds your share to your net worth.', [{ title: 'Northwind Studio', caption: '50% of ' + x(312000), value: x(156000), badge: sb('building.2.fill', 'var(--tint-company)') }, { title: 'Everyday', caption: 'Chase · Checking', value: x(48420.18), badge: b({ src: 'assets/banks/chase.png', shape: 'rounded' }) }, { title: 'Reserve', caption: 'Mercury · Savings', value: x(50000), badge: b({ src: 'assets/banks/mercury.png', shape: 'rounded' }) }]],
        Crypto: ['Coins, without connecting a wallet.', 'Enter what you hold. No wallet keys, no exchange logins.', [{ title: 'Bitcoin', caption: '2.4000 BTC', value: x(151488), change: 0.064, badge: b({ src: 'assets/coins/bitcoin.png', shape: 'circle' }) }, { title: 'Ethereum', caption: '18.5000 ETH', value: x(48878.85), change: -0.012, badge: b({ src: 'assets/coins/ethereum.png', shape: 'circle' }) }, { title: 'Solana', caption: '120 SOL', value: x(17586), change: 0.017, badge: b({ src: 'assets/coins/solana.png', shape: 'circle' }) }]],
        Families: ['The whole household, in one number.', 'Joint accounts, savings and the gold in the safe.', [{ title: 'Joint', caption: 'Bank of America · Checking', value: x(20000), badge: b({ src: 'assets/banks/bank-of-america.png', shape: 'rounded' }) }, { title: 'Savings', caption: 'Revolut · Savings', value: x(142650), badge: b({ src: 'assets/banks/revolut.png', shape: 'rounded' }) }, { title: 'Gold', caption: '40 ozt', value: x(105600), change: 0.018, badge: b({ metal: 'gold' }) }]],
        Freelancers: ['Know if this month was a good one.', 'Income in, spending out, in any currency.', [{ title: 'Income', caption: 'September 2026', value: x(24800), badge: sb('arrow.up.arrow.down.circle.fill', 'var(--tint-cash-flow)') }, { title: 'USD account', caption: 'Wise · US$63,240.00', value: x(63240), badge: b({ src: 'assets/banks/wise.png', shape: 'rounded' }) }, { title: 'Spending', caption: 'September 2026', value: x(11360.55), badge: sb('arrow.up.arrow.down.circle.fill', 'var(--tint-cash-flow)') }]],
      }[who];

      const bigVals = this.points(range, 7, f).map((p) => p.value), bigStat = this.stat(range, 7, f);
      const short = (v) => '$' + (v >= 1e6 ? (v / 1e6).toFixed(2) + 'M' : v >= 1e4 ? Math.round(v / 1e3) + 'K' : Math.round(v).toLocaleString('en-US'));

      return {
        tour,
        fieldRing: this.state.emailErr ? 'inset 0 0 0 1px rgba(255,69,58,.7)' : 'none',
        note: this.state.emailErr ? 'Enter a valid email address.' : 'One email when it’s ready. Your address isn’t used for anything else.',
        noteColor: this.state.emailErr ? '#FF453A' : 'rgba(255,255,255,.55)',
        vaultRows: [
          { title: 'Everyday', caption: 'Chase · Checking', value: x(48420.18), badge: b({ src: 'assets/banks/chase.png', shape: 'rounded' }) },
          { title: 'VTI', caption: '1,240 shares', value: x(348936), badge: b({ id: 'vti', symbol: 'VTI' }) },
          { title: 'Bitcoin', caption: '2.4000 BTC', value: x(151488), badge: b({ src: 'assets/coins/bitcoin.png', shape: 'circle' }) },
          { title: 'Gold', caption: '40 ozt', value: x(105600), badge: b({ metal: 'gold' }) },
        ],
        whoTitle: WHO[0], whoLine: WHO[1], whoRows: WHO[2],
        previewRows: [
          { title: 'Personal cash', caption: '5 accounts', value: x(cash), badge: sb('building.columns.fill', 'var(--tint-banks)') },
          { title: 'Stocks', caption: '2 holdings', value: x(stocks), change: 0.052, badge: sb('chart.line.uptrend.xyaxis', '#D670B3') },
          { title: 'Crypto', caption: '3 coins', value: x(crypto), change: 0.064, badge: b({ src: 'assets/coins/bitcoin.png', shape: 'circle' }) },
        ],
        noneRows: [
          { title: 'Account', caption: 'Nothing to sign up for', value: 'None', badge: sb('user-x', 'var(--color-brand)') },
          { title: 'Cloud sync', caption: 'Your vault stays on disk', value: 'Off', badge: sb('cloud-off', 'var(--color-brand)') },
          { title: 'Analytics and ads', caption: 'No tracking of any kind', value: 'None', badge: sb('eye.slash', 'var(--color-brand)') },
          { title: 'Bank logins', caption: 'Never asked for', value: 'None', badge: sb('key.fill', 'var(--color-brand)') },
        ],
        privacyNote: privacy ? 'On · Every amount on this page is a stand-in' : 'Off · Tap to hide every amount on this page',
        privacyNoteColor: privacy ? '#3AB57F' : 'rgba(255,255,255,.55)',
        privacyTrack: privacy ? '#3AB57F' : 'rgba(255,255,255,.12)',
        privacyGlow: privacy ? '0 0 40px rgba(58,181,127,.35)' : '0 0 0 rgba(0,0,0,0)',
        privacyThumb: privacy ? 'translateX(48px)' : 'translateX(0)',
        heroTotal: +(this.TOTAL * (0.93 + 0.07 * this.state.heroT) * f).toFixed(2),
        total: +(this.TOTAL * f).toFixed(2),
        heroPoints: this.points(heroRange, 3, f),
        heroStats: [this.stat(heroRange, 3, f), { label: 'All-time', value: '▲ 31.2%', color: 'var(--color-gain)', detail: '+' + this.money(324422 * f) }],
        ovTotal: +(this.TOTAL * (0.74 + 0.26 * (this.state.ovT ?? 1)) * f).toFixed(2),
        bigPoints: this.points(range, 7, f),
        ovChange: bigStat.value, ovChangeColor: bigStat.color, ovHigh: short(Math.max(...bigVals)), ovLow: short(Math.min(...bigVals)),
        bigStats: [bigStat, { label: 'All-time', value: '▲ 31.2%', color: 'var(--color-gain)', detail: '+' + x(324422) }],
        phonePoints: this.points(this.state.phoneRange, 5, f), phoneStats: [this.stat(this.state.phoneRange, 5, f)],
        groupRows: [
          { title: 'Personal cash', caption: '5 accounts', value: x(cash), badge: sb('building.columns.fill', 'var(--tint-banks)') },
          { title: 'Stocks', caption: '2 holdings', value: x(stocks), change: 0.052, badge: sb('chart.line.uptrend.xyaxis', '#D670B3') },
          { title: 'Crypto', caption: '3 coins', value: x(crypto), change: 0.064, badge: b({ src: 'assets/coins/bitcoin.png', shape: 'circle' }) },
          { title: 'Safe', caption: 'Gold and silver', value: x(metals), change: 0.018, badge: b({ metal: 'gold' }) },
          { title: 'Northwind Studio', caption: '50% of ' + x(312000), value: x(company), badge: sb('building.2.fill', 'var(--tint-company)') },
        ],
        bankRows: [
          { title: 'Everyday', caption: 'Chase · Checking', value: x(48420.18), badge: b({ src: 'assets/banks/chase.png', shape: 'rounded' }) },
          { title: 'Savings', caption: 'Revolut · Savings', value: x(142650), badge: b({ src: 'assets/banks/revolut.png', shape: 'rounded' }) },
          { title: 'USD account', caption: 'Wise · US$63,240.00', value: x(63240), badge: b({ src: 'assets/banks/wise.png', shape: 'rounded' }) },
          { title: 'Reserve', caption: 'Mercury · Savings', value: x(50000), badge: b({ src: 'assets/banks/mercury.png', shape: 'rounded' }) },
          { title: 'Joint', caption: 'Bank of America · Checking', value: x(20000), badge: b({ src: 'assets/banks/bank-of-america.png', shape: 'rounded' }) },
        ],
        assetRows: [
          { title: 'VTI', caption: '1,240 shares', value: x(348936), change: 0.041, badge: b({ id: 'vti', symbol: 'VTI' }) },
          { title: 'Bitcoin', caption: '2.4000 BTC', value: x(151488), change: 0.064, badge: b({ src: 'assets/coins/bitcoin.png', shape: 'circle' }) },
          { title: 'Ethereum', caption: '18.5000 ETH', value: x(48878.85), change: -0.012, badge: b({ src: 'assets/coins/ethereum.png', shape: 'circle' }) },
          { title: 'Gold', caption: '40 ozt', value: x(105600), change: 0.018, badge: b({ metal: 'gold' }) },
          { title: 'Northwind Studio', caption: 'Your 50% share', value: x(156000), badge: sb('building.2.fill', 'var(--tint-company)') },
        ],
        legend: slices.map((s) => ({ name: s.name, color: s.color, pct: Math.round((s.value / sliceTotal) * 100) + '%', amount: x(s.value) })),
        rings: slices.map((s, i) => { const r = 75 - i * 13.5, c = 2 * Math.PI * r, len = this.state.donut ? Math.max(0.001, (s.value / sliceTotal) * c) : 0.001; return { r, color: s.color, glow: 'color-mix(in srgb, ' + s.color + ' 45%, transparent)', dash: len.toFixed(2) + ' ' + c.toFixed(2), delay: (i * 90) + 'ms' }; }),
      };
    }

    render() {
      const v = this.vals();
      const { privacy, range, heroRange, phoneRange, who, pv, email, waitDone } = this.state;
      const rows = (list, opts) => list.map((r) => html`<${D.Row} key=${r.title} title=${r.title} caption=${r.caption} value=${r.value} change=${r.change} badge=${r.badge} chevron=${!!(opts && opts.chevron)} onClick=${opts && opts.onClick} />`);
      const check = html`<span style="flex:none;width:22px;height:22px;border-radius:11px;background:rgba(58,181,127,.16);display:flex;align-items:center;justify-content:center"><${D.Icon} name="checkmark" size=${14} color="#3AB57F" /></span>`;
      const cross = html`<span style="flex:none;width:22px;height:22px;border-radius:11px;background:rgba(255,255,255,.07);display:flex;align-items:center;justify-content:center"><${D.Icon} name="xmark" size=${13} color="rgba(255,255,255,.35)" /></span>`;
      const compare = [
        ['Your data stays on your device', 'Stored on their servers'],
        ['Never asks for your bank password', 'Asks for your bank password'],
        ['No account', 'Email, password, profile'],
        ['Banks, stocks, crypto, metals and companies', 'Usually one or two of those'],
        ['No ads, no tracking', 'Your spending is the product'],
      ];
      const tourSteps = [
        ['vault', '01', 'Its own vault', 'Built the same way: on-device and encrypted.', 'See it locked'],
        ['assets', '02', 'Every asset', 'Banks, stocks, crypto, metals and companies.', 'See every asset'],
        ['privacy', '03', 'Privacy mode', 'One tap hides every amount.', 'Try it'],
        ['onboard', '04', 'No account', 'No email. No password. Just open it.', 'See first launch'],
      ];
      const tabs = [['chart.line.uptrend.xyaxis', 'Assets', true], ['building.columns.fill', 'Accounts'], ['arrow.up.arrow.down', 'Cash flow'], ['gearshape.fill', 'Settings']];
      const footer = [
        ['Product', [['#overview', 'Overview'], ['#privacy', 'Privacy'], ['#iphone', 'iPhone waitlist'], ['#download', 'Download for Mac']]],
        ['Support', [['#top', 'Help center'], ['#privacy', 'Recovery codes'], ['#privacy', 'Backups'], ['#top', 'Contact']]],
        ['Company', [['#top', 'About'], ['#top', 'Press kit'], ['#privacy', 'Privacy policy'], ['#top', 'Terms']]],
      ];
      const words = [['Bank'], ['balances.'], ['Stocks.', '#D670B3'], ['Crypto.', '#D1852E'], ['Gold', '#D4A838'], ['and', '#D4A838'], ['silver.', '#D4A838'], ['The', '#8F6BDB'], ['companies', '#8F6BDB'], ['you', '#8F6BDB'], ['run.', '#8F6BDB'], ['One'], ['number,'], ['locked', '#3AB57F'], ['on', '#3AB57F'], ['your', '#3AB57F'], ['Mac.', '#3AB57F']];
      const ciphers = ['9f3a c1e0 7b44 02dd e8a1 5c9f', 'd0 4e 1a b7 33 fe 90 c2 6d 8b', 'f1c8 a09e 3d27 b5e6 0c41', '7e 2b c9 d4 81 0f 5a e3 96 1d', '4ab0 e7f2 19c3 6d58 aa0e 73b1', 'c5 38 f0 9a 2e 67 b1 d8 04 ec', '0e9d 5f3b a8c7 41e2 d6f0'];
      const navLink = (id, label) => html`<a data-navlink data-nav=${id} href=${'#' + id} class="uo-nav" style="position:relative;padding:6px 0;color:rgba(255,255,255,.55);text-decoration:none;transition:color .2s">${label}</a>`;

      return html`
<div ref=${this.rootRef} style="position:relative;min-height:100vh;background:#09090A;overflow-x:clip">

<nav data-navbar style="position:sticky;top:0;z-index:50;height:52px;background:rgba(9,9,10,.6);backdrop-filter:saturate(180%) blur(24px);-webkit-backdrop-filter:saturate(180%) blur(24px);box-shadow:inset 0 -0.5px 0 rgba(255,255,255,0);transition:box-shadow .3s ease,background .3s ease">
  <div style="max-width:980px;height:100%;margin:0 auto;padding:0 clamp(22px,5vw,48px);display:flex;align-items:center;justify-content:space-between;gap:24px;box-sizing:content-box">
    <a href="#top" aria-label="Up home" class="uo-home" style="display:flex;align-items:center;gap:10px;text-decoration:none"><img src="assets/up-icon.svg" decoding="sync" alt="" style="width:28px;height:28px;border-radius:7px;display:block;flex:none;box-shadow:0 0 0 0.5px rgba(255,255,255,.12)" /></a>
    <div style="display:flex;align-items:center;gap:clamp(18px,3vw,32px);font:500 13px var(--font-sans)">
      ${navLink('why', 'Why Up')}${navLink('overview', 'Overview')}${navLink('privacy', 'Privacy')}${navLink('iphone', 'iPhone')}
      <${D.PillButton} size="small" onClick=${this.goDownload}>Download<//>
    </div>
  </div>
</nav>

<header id="top" style="position:relative;padding:clamp(72px,9vw,112px) clamp(22px,5vw,48px) 0;text-align:center;isolation:isolate">
  <div style="position:absolute;left:50%;top:-48px;width:1500px;height:820px;margin-left:-750px;z-index:-1;pointer-events:none;animation:uoBreathe 9s ease-in-out infinite">
    <div style="width:100%;height:100%;background:radial-gradient(ellipse 50% 60% at 50% 0%,rgba(58,181,127,.22),rgba(58,181,127,.07) 55%,rgba(58,181,127,0) 100%);animation:uoDrift 17s ease-in-out infinite alternate"></div>
  </div>
  <div data-reveal style="display:flex;justify-content:center">
    <img src="assets/up-icon.svg" decoding="sync" alt="Up" style="width:84px;height:84px;border-radius:19px;display:block;flex:none;box-shadow:0 0 0 0.5px rgba(255,255,255,.12),0 20px 50px rgba(0,0,0,.5)" />
  </div>
  <h1 data-reveal data-delay="120" style="margin:36px auto 0;max-width:940px;font:700 clamp(48px,8.4vw,96px)/1.0 var(--font-display);letter-spacing:-.035em;color:#fff;text-wrap:balance">Everything you own.<br />Seen only by you.</h1>
  <p data-reveal data-delay="240" style="margin:28px auto 0;max-width:620px;font:400 clamp(19px,2vw,24px)/1.4 var(--font-sans);color:rgba(255,255,255,.55);letter-spacing:-.2px;text-wrap:pretty">Bank balances, stocks, crypto, metals and companies. Added up every month, privately, on your Mac.</p>
  <div data-reveal data-delay="360" style="margin-top:40px;display:flex;justify-content:center;flex-wrap:wrap;gap:12px">
    <${D.PillButton} size="large">Download for Mac<//>
    <${D.PillButton} size="large" variant="secondary" onClick=${this.goWaitlist}>Join the iPhone waitlist<//>
  </div>
  <div data-reveal data-delay="440" style="margin-top:22px;display:flex;justify-content:center;align-items:center;flex-wrap:wrap;gap:8px 18px;font-size:12px;color:rgba(255,255,255,.55)">
    <span style="display:flex;align-items:center;gap:6px;color:#3AB57F;font-weight:600"><${D.Icon} name="lock.fill" size=${12} color="#3AB57F" />Encrypted and only stored locally</span>
    <span>Requires macOS 26 · iPhone coming soon</span>
  </div>

  <div style="margin:clamp(64px,8vw,104px) auto 0;max-width:1120px">
    <div data-tilt style="position:relative;transform-origin:50% 0%">
      <div style="position:relative;height:clamp(660px,64vw,700px);border-radius:22px;overflow:hidden;background:#0E0E10;box-shadow:0 0 0 0.5px rgba(255,255,255,.14),0 60px 120px rgba(0,0,0,.6)">
        <div style="position:absolute;inset:0"><img src="assets/macos-wallpaper.jpg" alt="" style="width:100%;height:100%;object-fit:cover;display:block" /></div>
        <div style="position:relative;z-index:2;height:30px;display:flex;align-items:center;justify-content:space-between;gap:16px;padding:0 10px 0 18px;background:rgba(0,0,0,.18);backdrop-filter:blur(30px) saturate(160%);-webkit-backdrop-filter:blur(30px) saturate(160%);font:500 13px var(--font-sans);color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.25);white-space:nowrap;overflow:hidden">
          <div style="display:flex;align-items:center;gap:18px;min-width:0;overflow:hidden"><span style="font-weight:700">Finder</span><span>File</span><span>Edit</span><span>View</span><span>Go</span><span>Window</span><span>Help</span></div>
          <div style="display:flex;align-items:center;gap:16px;flex:none">
            <div data-mb-icon style="height:22px;padding:0 6px;border-radius:6px;background:rgba(255,255,255,.2);display:flex;align-items:center"><img src="assets/up-toolbar-18-dark.svg" alt="Up" style="width:18px;height:18px;display:block" /></div>
            <svg width="25" height="12" viewBox="0 0 25 12" aria-label="Battery" style="display:block"><rect x="0.5" y="0.5" width="21" height="11" rx="3.2" fill="none" stroke="rgba(255,255,255,.45)"></rect><rect x="2" y="2" width="18" height="8" rx="1.8" fill="#fff"></rect><path d="M23 4v4c.8-.3 1.3-1.1 1.3-2S23.8 4.3 23 4z" fill="rgba(255,255,255,.45)"></path></svg>
            <svg width="17" height="12" viewBox="0 0 17 12" aria-label="Wi-Fi" style="display:block"><path fill="#fff" d="M8.5 2.3c2.4 0 4.6.9 6.3 2.5.2.2.5.2.7 0l.9-.9c.2-.2.2-.5 0-.7C14.3 1.2 11.5 0 8.5 0S2.7 1.2.6 3.2c-.2.2-.2.5 0 .7l.9.9c.2.2.5.2.7 0C3.9 3.2 6.1 2.3 8.5 2.3zM8.5 5.8c1.4 0 2.7.5 3.7 1.4.2.2.5.2.7 0l.9-.9c.2-.2.2-.5 0-.7-1.4-1.3-3.3-2.1-5.3-2.1s-3.9.8-5.3 2.1c-.2.2-.2.5 0 .7l.9.9c.2.2.5.2.7 0 1-.9 2.3-1.4 3.7-1.4zM10.3 9.2c.2-.2.2-.6 0-.8-.5-.4-1.1-.6-1.8-.6s-1.3.2-1.8.6c-.2.2-.2.6 0 .8l1.4 1.4c.2.2.5.2.7 0l1.5-1.4z"></path></svg>
            <svg width="14" height="14" viewBox="0 0 14 14" aria-label="Spotlight" style="display:block"><circle cx="5.9" cy="5.9" r="4.6" fill="none" stroke="#fff" stroke-width="1.7"></circle><path d="M9.3 9.3l3.6 3.6" stroke="#fff" stroke-width="1.9" stroke-linecap="round"></path></svg>
            <svg width="17" height="14" viewBox="0 0 17 14" aria-label="Control Center" style="display:block"><rect x="0.75" y="0.75" width="15.5" height="5.5" rx="2.75" fill="none" stroke="#fff" stroke-width="1.5"></rect><circle cx="3.5" cy="3.5" r="1.6" fill="#fff"></circle><rect x="0.75" y="7.75" width="15.5" height="5.5" rx="2.75" fill="#fff"></rect><circle cx="13.5" cy="10.5" r="1.6" fill="#0E0E10"></circle></svg>
            <span>Sat Sep 26\u00a0\u00a02:20 PM</span>
          </div>
        </div>
        <div data-reveal data-delay="700" data-from="drop" data-mb-panel style="position:absolute;top:36px;right:clamp(12px,8%,96px);text-align:left">
          <div data-mb-fit style="transform-origin:100% 0">
          <${D.Panel}>
            <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:32px;margin:-2px 0 16px">
              <${D.SwitcherTitle} title="All assets" />
              <div style="display:flex;gap:8px">
                <${D.PrivacyButton} on=${privacy} onToggle=${this.togglePrivacy} />
                <${D.CircleButton} icon="plus" label="Add" />
                <${D.CircleButton} icon="ellipsis" label="More" />
              </div>
            </div>
            <${D.Amount} value=${v.heroTotal} cents=${true} />
            <${D.HeadlineStats} stats=${v.heroStats} style="margin-top:8px" />
            <div style="display:flex;flex-direction:column;gap:10px;margin-top:18px">
              <${D.Segments} value=${heroRange} onChange=${(r) => this.setState({ heroRange: r })} />
              <${D.LineChart} points=${v.heroPoints} hidden=${false} />
            </div>
            <${D.Card} style="margin-top:16px">
              ${rows(v.groupRows, { chevron: true, onClick: () => {} })}
            <//>
          <//>
          </div>
        </div>
      </div>
    </div>
  </div>
</header>

<section style="padding:clamp(120px,16vw,200px) clamp(22px,5vw,48px) clamp(112px,14vw,180px);">
  <p data-words style="margin:0 auto;max-width:920px;font:700 clamp(34px,5.4vw,60px)/1.12 var(--font-display);letter-spacing:-.025em;color:#fff;text-wrap:pretty">
    ${words.map(([w, c], i) => html`<${React.Fragment} key=${i}>${i ? ' ' : ''}<span data-w style=${c ? 'color:' + c : ''}>${w}</span><//>`)}
  </p>
</section>

<section id="why" style="padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px);scroll-margin-top:48px">
  <div style="max-width:980px;margin:0 auto">
    <div style="text-align:center">
      <h2 data-sh style="margin:0 auto;max-width:820px;font:700 clamp(40px,5.6vw,72px)/1.05 var(--font-display);letter-spacing:-.03em;color:#fff;text-wrap:balance">Most money apps want your logins.</h2>
      <p data-reveal style="margin:20px auto 0;max-width:560px;font-size:clamp(17px,1.7vw,21px);line-height:1.42;color:rgba(255,255,255,.55);text-wrap:pretty">They sync your bank to their cloud, and still miss your crypto, gold and companies. Up does the opposite.</p>
    </div>
    <div data-reveal data-tile style="margin-top:clamp(48px,6vw,72px);background:rgba(255,255,255,.07);border-radius:28px;padding:clamp(20px,3vw,32px) clamp(20px,4vw,40px)">
      <div style="display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:0 clamp(16px,4vw,48px);padding:0 0 14px;font:600 13px var(--font-sans);color:rgba(255,255,255,.55)">
        <div style="display:flex;align-items:center;gap:10px;color:#fff"><img src="assets/up-icon.svg" alt="" style="width:24px;height:24px;border-radius:6px;display:block" />Up</div>
        <div style="display:flex;align-items:center">Typical money apps</div>
      </div>
      <div data-stagger>
        ${compare.map(([yes, no]) => html`
        <div key=${yes} style="display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:0 clamp(16px,4vw,48px);padding:14px 0;box-shadow:inset 0 0.5px 0 rgba(255,255,255,.08)">
          <div style="display:flex;align-items:flex-start;gap:10px;font:600 clamp(14px,1.5vw,16px)/1.35 var(--font-sans);color:#fff">${check}${yes}</div>
          <div style="display:flex;align-items:flex-start;gap:10px;font:500 clamp(14px,1.5vw,16px)/1.35 var(--font-sans);color:rgba(255,255,255,.55)">${cross}${no}</div>
        </div>`)}
      </div>
    </div>
  </div>
</section>

<section id="overview" style="padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px);scroll-margin-top:48px">
  <div style="max-width:1080px;margin:0 auto">
    <div data-reveal style="text-align:center">
      <h2 data-sh style="margin:0;font:700 clamp(40px,5.6vw,72px)/1.05 var(--font-display);letter-spacing:-.03em;color:#fff;text-wrap:balance">Every high. Every dip.</h2>
      <p style="margin:20px auto 0;max-width:560px;font-size:clamp(17px,1.7vw,21px);line-height:1.42;color:rgba(255,255,255,.55);text-wrap:pretty">From the last 24 hours to the day you started, as one line.</p>
    </div>
    <div data-ov style="margin-top:clamp(40px,5vw,56px);display:flex;flex-direction:column;align-items:center;text-align:left">
      <div style="font:600 13px var(--font-sans);color:rgba(255,255,255,.55);margin-bottom:14px">All assets</div>
      <div style="transform:scale(1.75);transform-origin:50% 50%;margin:12px 0 24px">
        <${D.Amount} value=${v.ovTotal} />
      </div>
      <${D.HeadlineStats} stats=${v.bigStats} style="margin-top:6px;width:min(100%,380px)" />
    </div>
    <div style="position:relative;margin:8px calc(50% - 50vw) 0;padding:40px 0 16px;isolation:isolate">
      <div aria-hidden="true" style="position:absolute;inset:0;z-index:-1;background-image:radial-gradient(circle,rgba(255,255,255,.11) 1px,transparent 1.4px);background-size:22px 22px;background-position:11px 11px;-webkit-mask-image:linear-gradient(transparent,#000 12%,#000 88%,transparent);mask-image:linear-gradient(transparent,#000 12%,#000 88%,transparent)"></div>
      <div data-draw style="position:relative;max-width:calc(980px + 2 * clamp(22px,5vw,48px));margin:0 auto;padding:0 clamp(22px,5vw,48px);box-sizing:border-box">
        <${D.LineChart} points=${v.bigPoints} height=${300} />
      </div>
    </div>
    <div data-reveal style="margin-top:20px;display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:16px 32px">
      <div style="width:min(100%,320px)">
        <${D.Segments} value=${range} onChange=${(r) => this.morphRange(r)} />
      </div>
      <div style="display:flex;align-items:baseline;gap:22px;font:600 15px var(--font-sans);font-variant-numeric:tabular-nums;white-space:nowrap">
        <span style="color:${v.ovChangeColor}">${v.ovChange}</span>
        <span style="color:rgba(255,255,255,.85)"><span style="color:rgba(255,255,255,.55);font-weight:500;margin-right:5px">H</span>${v.ovHigh}</span>
        <span style="color:rgba(255,255,255,.85)"><span style="color:rgba(255,255,255,.55);font-weight:500;margin-right:5px">L</span>${v.ovLow}</span>
      </div>
    </div>
  </div>
</section>

<section style="padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px);">
  <div style="max-width:980px;margin:0 auto">
    <h2 data-sh style="margin:0 0 56px;font:600 clamp(28px,3.6vw,40px)/1.15 var(--font-display);letter-spacing:-.028em;color:#fff;max-width:640px;text-wrap:balance">One vault. <span style="color:rgba(255,255,255,.55)">Every kind of asset you own.</span></h2>
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));gap:20px">
      <div data-reveal data-tile style="background:rgba(255,255,255,.07);border-radius:28px;padding:40px 36px 32px;display:flex;flex-direction:column;gap:28px;min-width:0">
        <div>
          <${D.SymbolBadge} icon="building.columns.fill" tint="var(--tint-banks)" size=${40} />
          <h3 style="margin:18px 0 8px;font:700 28px/1.12 var(--font-display);letter-spacing:-.5px;color:#fff">Every account</h3>
          <p style="margin:0;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">Any bank, any currency. Type a balance or read it from a statement.</p>
        </div>
        <div data-stagger style="margin-top:auto">${rows(v.bankRows)}</div>
      </div>
      <div data-reveal data-delay="100" data-tile style="background:rgba(255,255,255,.07);border-radius:28px;padding:40px 36px 32px;display:flex;flex-direction:column;gap:28px;min-width:0">
        <div>
          <${D.SymbolBadge} icon="chart.line.uptrend.xyaxis" tint="#D670B3" size=${40} />
          <h3 style="margin:18px 0 8px;font:700 28px/1.12 var(--font-display);letter-spacing:-.5px;color:#fff">Stocks, coins, metals and your companies</h3>
          <p style="margin:0;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">Enter what you hold. Prices update on their own.</p>
        </div>
        <div data-stagger style="margin-top:auto">${rows(v.assetRows)}</div>
      </div>
      <div data-reveal data-tile style="grid-column:1 / -1;background:rgba(255,255,255,.07);border-radius:28px;padding:40px 36px;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));gap:32px 56px;align-items:center;min-width:0">
        <div>
          <${D.SymbolBadge} icon="chart-pie" tint="var(--tint-net-worth)" size=${40} />
          <h3 style="margin:18px 0 8px;font:700 28px/1.12 var(--font-display);letter-spacing:-.5px;color:#fff">Where it sits</h3>
          <p style="margin:0;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">How much is cash, and how much rides on the market.</p>
        </div>
        <div data-donut style="display:grid;grid-template-columns:auto minmax(0,1fr);align-items:center;gap:clamp(20px,3vw,32px);margin-top:auto">
          <svg width="160" height="160" viewBox="0 0 160 160" aria-hidden="true" style="flex:none;display:block;transform:rotate(-90deg);overflow:visible">
            ${v.rings.map((g, i) => html`<g key=${i}>
              <circle cx="80" cy="80" r=${g.r} fill="none" stroke-width="10" style="stroke:${g.color};stroke-opacity:.16"></circle>
              <circle cx="80" cy="80" r=${g.r} fill="none" stroke-width="10" stroke-linecap="round" stroke-dasharray=${g.dash} style="stroke:${g.color};transition:stroke-dasharray 1.3s cubic-bezier(.2,.8,.2,1) ${g.delay};filter:drop-shadow(0 0 3px ${g.glow})"></circle>
            </g>`)}
          </svg>
          <div style="min-width:0;max-width:280px;display:flex;flex-direction:column;gap:10px">
            ${v.legend.map((s) => html`
            <div key=${s.name} style="display:grid;grid-template-columns:10px minmax(0,1fr) auto;align-items:center;column-gap:10px">
              <span style="width:10px;height:10px;border-radius:5px;background:${s.color}"></span>
              <span style="font:600 13px/1.3 var(--font-sans);color:rgba(255,255,255,.85);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${s.name}</span>
              <span style="font:600 13px/1.3 var(--font-sans);color:#fff;font-variant-numeric:tabular-nums">${s.pct}</span>
              <span></span>
              <span style="grid-column:2 / 4;font:400 11px/1.3 var(--font-sans);color:rgba(255,255,255,.55);font-variant-numeric:tabular-nums">${s.amount}</span>
            </div>`)}
          </div>
        </div>
      </div>
    </div>
  </div>
</section>

<section id="who" style="padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px)">
  <div style="max-width:980px;margin:0 auto">
    <div style="text-align:center">
      <h2 data-sh style="margin:0 auto;max-width:760px;font:700 clamp(40px,5.6vw,72px)/1.05 var(--font-display);letter-spacing:-.03em;color:#fff;text-wrap:balance">Whatever you own.</h2>
      <p data-reveal style="margin:20px auto 0;max-width:520px;font-size:clamp(17px,1.7vw,21px);line-height:1.42;color:rgba(255,255,255,.55);text-wrap:pretty">Pick what sounds like you.</p>
    </div>
    <div style="width:min(100%,460px);margin:40px auto 0"><${D.Segments} options=${['Founders', 'Crypto', 'Families', 'Freelancers']} value=${who} onChange=${(w) => this.setState({ who: w })} label="Who it’s for" /></div>
    <div data-reveal data-tile style="margin-top:20px;background:rgba(255,255,255,.07);border-radius:28px;padding:clamp(28px,4vw,44px);display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,340px),1fr));gap:32px 56px;align-items:center">
      <div style="min-width:0">
        <div style="font:600 13px var(--font-sans);color:#3AB57F;margin-bottom:12px">${who}</div>
        <div style="font:700 clamp(24px,2.6vw,30px)/1.2 var(--font-display);letter-spacing:-.5px;color:#fff;text-wrap:balance">${v.whoTitle}</div>
        <div style="margin-top:12px;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">${v.whoLine}</div>
      </div>
      <div style="min-width:0;background:#09090A;border-radius:20px;padding:12px;box-shadow:inset 0 0 0 0.5px rgba(255,255,255,.08)">
        ${rows(v.whoRows)}
      </div>
    </div>
  </div>
</section>

<section id="privacy" style="position:relative;padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px);scroll-margin-top:48px;isolation:isolate">
  <div aria-hidden="true" style="position:absolute;left:50%;top:-120px;width:1400px;height:1100px;margin-left:-700px;z-index:-1;pointer-events:none;background:radial-gradient(ellipse 40% 38% at 50% 42%,rgba(58,181,127,.13),rgba(58,181,127,0) 100%)"></div>
  <div style="max-width:980px;margin:0 auto">
  <div style="text-align:center">
    <div data-reveal style="display:flex;justify-content:center">
      <img src="assets/privacy-shield.png" alt="" style="width:104px;height:auto;display:block;filter:drop-shadow(0 18px 50px rgba(58,181,127,.35))" />
    </div>
    <div style="height:20px"></div>
    <h2 data-sh style="margin:12px auto 0;max-width:860px;font:700 clamp(40px,5.6vw,72px)/1.05 var(--font-display);letter-spacing:-.035em;color:#fff;text-wrap:balance">Your balances never leave your Mac.</h2>
    <p data-reveal data-delay="200" style="margin:24px auto 0;max-width:600px;font-size:clamp(17px,1.7vw,21px);line-height:1.42;color:rgba(255,255,255,.55);text-wrap:pretty">No account. No cloud. An encrypted vault on your Mac, and only you hold the key.</p>
  </div>

  <div data-reveal style="margin-top:80px;background:rgba(255,255,255,.07);border-radius:32px;padding:clamp(28px,4vw,48px)">
    <h3 style="margin:0;font:700 clamp(28px,3.4vw,40px)/1.1 var(--font-display);letter-spacing:-.8px;color:#fff;max-width:560px;text-wrap:balance">Encrypted before it touches the disk.</h3>
    <p style="margin:12px 0 0;max-width:520px;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">AES-256 encryption, with the key in your Mac’s protected Keychain. On disk, without it, it’s noise.</p>
    <div style="margin-top:36px;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:16px;align-items:stretch">
      <div style="background:rgba(255,255,255,.07);border-radius:20px;padding:18px 20px">
        <div style="display:flex;align-items:center;gap:8px;font:600 13px var(--font-sans);color:rgba(255,255,255,.55);margin-bottom:10px"><${D.Icon} name="eye" size=${13} color="rgba(255,255,255,.55)" />What you see</div>
        ${rows(v.vaultRows)}
      </div>
      <div style="background:#050506;border-radius:20px;padding:18px 20px;box-shadow:inset 0 0 0 0.5px rgba(255,255,255,.08);overflow:hidden">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;font:600 13px var(--font-sans);color:rgba(255,255,255,.55);margin-bottom:14px">
          <span style="display:flex;align-items:center;gap:8px"><${D.Icon} name="lock.fill" size=${13} color="#3AB57F" />What’s on disk</span>
          <span style="font:500 11px var(--font-mono);color:rgba(255,255,255,.55)">vault.up</span>
        </div>
        <div style="display:flex;flex-direction:column;gap:10px;font:500 13px/1.35 var(--font-mono);color:rgba(58,181,127,.9);letter-spacing:.02em;white-space:nowrap">
          ${ciphers.map((c, i) => html`<span key=${i} data-cipher>${c}</span>`)}
        </div>
      </div>
    </div>
  </div>

  <div style="margin-top:20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));gap:20px">
    <div data-reveal data-tile style="grid-column:1 / -1;background:rgba(255,255,255,.07);border-radius:28px;padding:40px 36px 32px;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,320px),1fr));gap:32px 56px;align-items:center;min-width:0">
      <div>
        <${D.SymbolBadge} icon="server-off" tint="var(--color-brand)" size=${40} />
        <h3 style="margin:18px 0 8px;font:700 28px/1.12 var(--font-display);letter-spacing:-.5px;color:#fff"><span style="color:#3AB57F">0</span> servers hold your data.</h3>
        <p style="margin:0;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">No Up cloud to breach, sell or subpoena.</p>
      </div>
      <div data-stagger style="margin-top:auto">${rows(v.noneRows)}</div>
    </div>
  </div>

  <div data-reveal data-tile style="margin-top:20px;background:rgba(255,255,255,.07);border-radius:28px;padding:clamp(28px,4vw,48px);display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,340px),1fr));gap:clamp(32px,5vw,64px);align-items:center">
    <div style="display:flex;flex-direction:column;gap:28px;min-width:0">
      <div>
        <${D.SymbolBadge} icon="eye.slash" tint="var(--tint-net-worth)" size=${40} />
        <h3 style="margin:18px 0 8px;font:700 clamp(28px,3.4vw,40px)/1.1 var(--font-display);letter-spacing:-.8px;color:#fff;text-wrap:balance">Open it anywhere.</h3>
        <p style="margin:0;max-width:420px;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55);text-wrap:pretty">Swaps every amount for a stand-in that keeps its percentages. For trains, meetings and shared screens.</p>
      </div>
      <div role="switch" tabIndex="0" onClick=${this.togglePrivacy} onKeyDown=${onKeys(this.togglePrivacy)} aria-checked=${privacy} aria-label="Privacy mode" style="align-self:flex-start;display:flex;align-items:center;gap:20px;cursor:pointer;user-select:none">
        <div style="position:relative;flex:none;width:112px;height:64px;border-radius:32px;background:${v.privacyTrack};box-shadow:inset 0 0 0 0.5px rgba(255,255,255,.14),${v.privacyGlow};transition:background .35s cubic-bezier(.2,.8,.2,1),box-shadow .35s">
          <div style="position:absolute;top:6px;left:6px;width:52px;height:52px;border-radius:26px;background:#fff;box-shadow:0 3px 10px rgba(0,0,0,.35),0 0 0 0.5px rgba(0,0,0,.08);display:flex;align-items:center;justify-content:center;transform:${v.privacyThumb};transition:transform .45s cubic-bezier(.3,1.35,.5,1)">
            <${D.Icon} name=${privacy ? 'eye.slash' : 'eye'} size=${22} color="#09090A" />
          </div>
        </div>
        <div>
          <div style="font:600 20px/1.25 var(--font-display);letter-spacing:-.2px;color:#fff">Privacy mode</div>
          <div style="margin-top:4px;font:500 14px/1.4 var(--font-sans);color:${v.privacyNoteColor};transition:color .3s">${v.privacyNote}</div>
        </div>
      </div>
    </div>
    <div style="display:flex;justify-content:center;min-width:0">
      <${D.Panel} style="width:min(100%,344px)">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:32px;margin:-2px 0 16px">
          <${D.SwitcherTitle} title="All assets" />
          <${D.PrivacyButton} on=${privacy} onToggle=${this.togglePrivacy} />
        </div>
        <${D.Amount} value=${v.total} />
        <${D.HeadlineStats} stats=${v.heroStats} style="margin-top:8px" />
        <div style="margin-top:16px">
          <${D.Card}>${rows(v.previewRows)}<//>
        </div>
      <//>
    </div>
  </div>
  </div>
</section>

<section style="padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px)">
  <div data-reveal style="max-width:980px;margin:0 auto;text-align:center">
    <div style="font:600 13px var(--font-sans);color:rgba(255,255,255,.55)">Bytes of your data we’ve collected</div>
    <div style="margin-top:8px;font:700 clamp(96px,16vw,200px)/1 var(--font-display);letter-spacing:-.04em;color:#3AB57F;font-variant-numeric:tabular-nums">0</div>
    <div style="margin-top:12px;font:500 15px var(--font-sans);color:rgba(255,255,255,.55);font-variant-numeric:tabular-nums">And there’s nowhere for it to go.</div>
  </div>
  <div data-reveal style="max-width:640px;margin:clamp(96px,12vw,140px) auto 0;text-align:left">
    <div style="font:600 13px var(--font-sans);color:#3AB57F;margin-bottom:14px">Why we built Up</div>
    <p style="margin:0;font:600 clamp(22px,2.6vw,30px)/1.35 var(--font-display);letter-spacing:-.3px;color:#fff;text-wrap:pretty">Every money app we tried stored our finances on their servers. None of them were private. So we built the one we wanted: everything we own, in one place, stored locally on our device and encrypted.</p>
    <div style="margin-top:20px;display:flex;align-items:center;gap:12px;font-size:14px;color:rgba(255,255,255,.55)"><img src="assets/up-icon.svg" alt="" style="width:32px;height:32px;border-radius:8px;display:block" />The Up team</div>
  </div>
</section>

<section id="iphone" style="padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px);scroll-margin-top:48px;position:relative;isolation:isolate;overflow:clip;text-align:center">
  <div aria-hidden="true" style="position:absolute;left:50%;bottom:0;width:1200px;height:1000px;margin-left:-600px;z-index:-1;pointer-events:none;background:radial-gradient(ellipse 38% 42% at 50% 62%,rgba(58,181,127,.14),rgba(58,181,127,0) 100%)"></div>
  <div style="max-width:980px;margin:0 auto">
    <div data-reveal>
      <div style="display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:14px"><span style="font:600 17px/1.2 var(--font-sans);color:#3AB57F">iPhone</span><span style="font:600 11px/1 var(--font-sans);color:#3AB57F;background:rgba(58,181,127,.14);padding:5px 9px;border-radius:999px">Coming soon</span></div>
      <h2 data-sh style="margin:0 auto;max-width:760px;font:700 clamp(40px,6vw,72px)/1.05 var(--font-display);letter-spacing:-.03em;color:#fff;text-wrap:balance">Soon, in your pocket too.</h2>
      <p style="margin:20px auto 0;max-width:560px;font-size:clamp(17px,1.7vw,21px);line-height:1.42;color:rgba(255,255,255,.55);text-wrap:pretty">The same private, on-device design, on your phone.</p>
    </div>
    <div data-reveal data-delay="120">
      ${!waitDone ? html`
        <form onSubmit=${this.submitWaitlist} style="margin:36px auto 0;max-width:460px;text-align:left;display:flex;flex-direction:column;gap:10px">
          <div style="display:flex;gap:8px;padding:5px;border-radius:999px;background:rgba(255,255,255,.07);box-shadow:${v.fieldRing};transition:box-shadow .2s">
            <input ref=${this.emailRef} type="email" placeholder="Email address" value=${email} onChange=${(e) => this.setState({ email: e.target.value, emailErr: false })} aria-label="Email address" style="flex:1;min-width:0;height:40px;padding:0 16px;border:0;outline:0;background:transparent;color:rgba(255,255,255,.85);font:400 15px var(--font-sans)" />
            <${D.PillButton} size="large" onClick=${this.submitWaitlist}>Join waitlist<//>
          </div>
          <div style="padding:0 16px;font-size:12px;line-height:1.4;color:${v.noteColor}">${v.note}</div>
        </form>` : html`
        <div style="margin:36px auto 0;max-width:460px;text-align:left;display:flex;align-items:center;gap:14px;padding:16px 20px;border-radius:20px;background:rgba(255,255,255,.07)">
          <div style="width:32px;height:32px;border-radius:16px;background:rgba(58,181,127,.16);display:flex;align-items:center;justify-content:center;flex:none">
            <${D.Icon} name="checkmark" size=${16} color="#3AB57F" />
          </div>
          <div>
            <div style="font:600 15px/1.3 var(--font-sans);color:#fff">You’re on the list</div>
            <div style="margin-top:2px;font-size:13px;line-height:1.4;color:rgba(255,255,255,.55)">We’ll email ${email} once, when Up for iPhone is ready.</div>
          </div>
        </div>`}
    </div>
    <div data-tour style="margin-top:clamp(40px,5vw,64px);display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,340px),1fr));gap:0 clamp(32px,6vw,80px);text-align:left">
      <div style="min-width:0">
        ${tourSteps.map(([k, n, title, line, cta], i) => { const t = v.tour[k]; return html`
        <div key=${k} data-step=${i} style="min-height:min(78vh,640px);display:flex;flex-direction:column;justify-content:center;transition:opacity .5s ease">
          <div style="font:600 13px var(--font-sans);color:#3AB57F;margin-bottom:10px">${n}</div>
          <div style="font:700 clamp(28px,3.4vw,40px)/1.1 var(--font-display);letter-spacing:-.8px;color:#fff">${title}</div>
          <div style="margin-top:10px;max-width:360px;font-size:17px;line-height:1.45;color:rgba(255,255,255,.55)">${line}</div>
          <div role="button" tabIndex="0" onClick=${t.show} onKeyDown=${onKeys(t.show)} style="align-self:flex-start;margin-top:14px;display:inline-flex;align-items:center;gap:6px;height:32px;padding:0 14px 0 11px;border-radius:16px;cursor:pointer;font:600 12px var(--font-sans);color:${t.c};background:${t.bg};transition:background .2s,color .2s"><span style="font-size:14px;line-height:1">${t.i}</span>${cta}</div>
        </div>`; })}
      </div>
      <div style="min-width:0;order:-1">
        <div style="position:sticky;top:max(64px,calc(50vh - 336px));display:flex;justify-content:center;text-align:left">
          <div style="position:relative;width:322px;height:672px;border-radius:58px;padding:9px;box-sizing:border-box;background:linear-gradient(145deg,#3A3A3C,#1C1C1E 30%,#141415 70%,#2C2C2E);box-shadow:inset 0 0 0 1px rgba(255,255,255,.16),inset 0 0 0 3px #0B0B0C,0 50px 100px rgba(0,0,0,.6)">
            <div style="position:absolute;left:-3px;top:120px;width:3px;height:30px;border-radius:2px 0 0 2px;background:#2C2C2E"></div>
            <div style="position:absolute;left:-3px;top:170px;width:3px;height:56px;border-radius:2px 0 0 2px;background:#2C2C2E"></div>
            <div style="position:absolute;left:-3px;top:236px;width:3px;height:56px;border-radius:2px 0 0 2px;background:#2C2C2E"></div>
            <div style="position:absolute;right:-3px;top:190px;width:3px;height:86px;border-radius:0 2px 2px 0;background:#2C2C2E"></div>
            <div style="position:relative;width:100%;height:100%;border-radius:49px;overflow:hidden;background:#09090A;isolation:isolate">
              <${D.Backdrop} animate=${this.motion} />
              <div style="position:absolute;top:11px;left:50%;width:98px;height:29px;margin-left:-49px;border-radius:15px;background:#000;z-index:3"></div>
              <div style="position:relative;z-index:2;height:54px;display:flex;align-items:center;justify-content:space-between;padding:6px 30px 0 40px;box-sizing:border-box;font:600 15px var(--font-sans);color:#fff">
                <span>9:41</span>
                <span style="width:25px;height:12px;border-radius:4px;box-shadow:inset 0 0 0 1px rgba(255,255,255,.4);padding:2px;box-sizing:border-box;display:flex"><span style="width:75%;background:#fff;border-radius:1.5px"></span></span>
              </div>
              <div style="position:relative;z-index:2;padding:4px 18px 0">
                <div style="display:flex;align-items:center;justify-content:space-between;height:36px">
                  <div style="display:flex;align-items:center;gap:6px;height:28px;padding:0 11px;border-radius:14px;background:rgba(58,181,127,.14);font:600 11px var(--font-sans);color:#3AB57F"><${D.Icon} name="lock.fill" size=${11} color="#3AB57F" />On this iPhone</div>
                  <div style="display:flex;gap:8px">
                    <${D.PrivacyButton} on=${privacy} onToggle=${this.togglePrivacy} />
                    <${D.CircleButton} icon="plus" label="Add" />
                    <${D.CircleButton} icon="ellipsis" label="More" />
                  </div>
                </div>
                <div style="margin-top:12px;font:700 32px/1.1 var(--font-display);letter-spacing:-.6px;color:#fff">All assets</div>
                <${D.Amount} value=${v.total} cents=${true} style="margin-top:8px" />
                <${D.HeadlineStats} stats=${v.phoneStats} style="margin-top:6px" />
                <div style="display:flex;flex-direction:column;gap:8px;margin-top:16px">
                  <${D.Segments} value=${phoneRange} onChange=${(r) => this.setState({ phoneRange: r })} />
                  <${D.LineChart} points=${v.phonePoints} height=${118} />
                </div>
                <div style="margin:20px 0 8px;font:700 20px/1.2 var(--font-display);letter-spacing:-.3px;color:#fff">Holdings</div>
                <${D.Card}>${rows(v.groupRows, { chevron: true })}<//>
              </div>
              <div style="position:absolute;left:0;right:0;bottom:0;height:150px;z-index:3;pointer-events:none;background:linear-gradient(rgba(9,9,10,0),rgba(9,9,10,.85) 55%,#09090A)"></div>
              <div aria-hidden=${!pv} style="position:absolute;inset:0;z-index:6;border-radius:49px;overflow:hidden;pointer-events:${pv ? 'auto' : 'none'}">
                <div style="position:absolute;inset:0;opacity:${v.tour.vault.op};transform:${v.tour.vault.tf};transition:opacity .45s ease,transform .55s cubic-bezier(.22,.7,.2,1);background:rgba(9,9,10,.82);backdrop-filter:blur(22px);-webkit-backdrop-filter:blur(22px);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:0 36px;text-align:center">
                  <img src="assets/privacy-shield.png" alt="" style="width:64px;height:auto;display:block;filter:drop-shadow(0 12px 30px rgba(58,181,127,.35))" />
                  <div style="font:700 22px/1.2 var(--font-display);color:#fff">Up is locked</div>
                  <div style="font-size:13px;line-height:1.45;color:rgba(255,255,255,.55)">Your vault is encrypted and stored only on this iPhone.</div>
                  <div style="margin-top:8px;height:40px;padding:0 28px;border-radius:20px;background:#fff;color:#000;font:600 13px/40px var(--font-sans)">Unlock</div>
                </div>
                <div style="position:absolute;inset:0;opacity:${v.tour.assets.op};transform:${v.tour.assets.tf};transition:opacity .45s ease,transform .55s cubic-bezier(.22,.7,.2,1);background:#09090A;padding:64px 18px 0;text-align:left">
                  <div style="font:700 28px/1.1 var(--font-display);letter-spacing:-.5px;color:#fff;margin-bottom:14px">Every asset</div>
                  <${D.Card}>${rows(v.groupRows, { chevron: true })}<//>
                </div>
                <div style="position:absolute;inset:0;opacity:${v.tour.onboard.op};transform:${v.tour.onboard.tf};transition:opacity .45s ease,transform .55s cubic-bezier(.22,.7,.2,1);background:#09090A;display:flex;flex-direction:column;justify-content:center;gap:10px;padding:0 26px;text-align:left">
                  <img src="assets/up-icon.svg" alt="" style="width:56px;height:56px;border-radius:13px;display:block;margin-bottom:10px" />
                  <div style="font:700 26px/1.15 var(--font-display);letter-spacing:-.4px;color:#fff">Start with one balance</div>
                  <div style="font-size:13px;line-height:1.5;color:rgba(255,255,255,.55)">A bank account, some crypto, gold or silver, or an income and spending statement. Add more any time with the plus button.</div>
                  <div style="margin-top:14px;height:40px;border-radius:20px;background:#fff;color:#000;text-align:center;font:600 13px/40px var(--font-sans)">Add</div>
                  <div style="margin-top:6px;font-size:11px;color:rgba(255,255,255,.55);text-align:center">No account. No email. Nothing leaves this iPhone.</div>
                </div>
              </div>
              <div style="position:absolute;left:14px;right:14px;bottom:22px;height:60px;z-index:4;padding:5px;box-sizing:border-box;border-radius:30px;background:rgba(44,44,46,.72);backdrop-filter:blur(24px) saturate(180%);-webkit-backdrop-filter:blur(24px) saturate(180%);box-shadow:inset 0 0 0 0.5px rgba(255,255,255,.14),0 12px 30px rgba(0,0,0,.45);display:grid;grid-template-columns:repeat(4,1fr);gap:2px">
                ${tabs.map(([icon, label, active]) => html`
                <div key=${label} style="display:flex;flex-direction:column;align-items:center;justify-content:center;gap:3px;border-radius:24px;${active ? 'background:rgba(255,255,255,.12);color:#fff' : 'color:rgba(255,255,255,.55)'}"><${D.Icon} name=${icon} size=${19} color=${active ? '#fff' : 'rgba(255,255,255,.55)'} /><span style="font:600 10px/1 var(--font-sans)">${label}</span></div>`)}
              </div>
              <div style="position:absolute;bottom:8px;left:50%;width:120px;height:4px;margin-left:-60px;border-radius:2px;background:rgba(255,255,255,.55);z-index:5"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</section>

<section id="download" style="position:relative;padding:0 clamp(22px,5vw,48px) clamp(112px,13vw,176px);text-align:center;isolation:isolate;scroll-margin-top:48px">
  <div style="position:absolute;left:50%;bottom:0;width:1200px;height:600px;margin-left:-600px;z-index:-1;pointer-events:none;background:radial-gradient(ellipse 50% 60% at 50% 100%,rgba(58,181,127,.16),rgba(58,181,127,0) 70%)"></div>
  <div data-reveal style="display:flex;justify-content:center"><img src="assets/up-icon.svg" decoding="sync" alt="Up" style="width:128px;height:128px;border-radius:29px;display:block;flex:none;box-shadow:0 30px 80px rgba(58,181,127,.25)" /></div>
  <h2 data-sh style="margin:44px auto 0;max-width:760px;font:700 clamp(40px,6vw,72px)/1.05 var(--font-display);letter-spacing:-.03em;color:#fff;text-wrap:balance">Know your number.<br />Keep it yours.</h2>
  <p data-reveal data-delay="160" style="margin:20px auto 0;max-width:480px;font-size:clamp(17px,1.7vw,21px);line-height:1.42;color:rgba(255,255,255,.55)">Available now for Mac. Coming soon to iPhone.</p>
  <div data-reveal data-delay="220" style="margin-top:34px;display:flex;justify-content:center;flex-wrap:wrap;gap:12px">
    <${D.PillButton} size="large">Download for Mac<//>
    <${D.PillButton} size="large" variant="secondary" onClick=${this.goWaitlist}>Join the iPhone waitlist<//>
  </div>
  <div style="font:600 12px var(--font-sans);color:rgba(255,255,255,.55);display:flex;justify-content:center;flex-wrap:wrap;gap:6px 14px;margin-top:16px"><span>Free to try</span><span>·</span><span>Works offline</span><span>·</span><span>No account needed</span></div>
</section>

<footer style="position:relative;overflow:hidden;padding:clamp(72px,9vw,112px) clamp(22px,5vw,48px) 40px;box-shadow:inset 0 0.5px 0 rgba(255,255,255,.08)">
  <div style="max-width:980px;margin:0 auto">
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,150px),1fr));gap:40px 32px">
      <div style="display:flex;flex-direction:column;gap:14px;min-width:0;grid-column:1 / -1;max-width:320px;margin-bottom:8px">
        <img src="assets/up-icon.svg" decoding="sync" alt="Up" style="width:40px;height:40px;border-radius:9px;display:block" />
        <div style="font:600 15px/1.4 var(--font-display);color:#fff;max-width:240px">Your net worth, on your Mac. Nowhere else.</div>
        <div style="display:flex;align-items:center;gap:6px;font:600 12px var(--font-sans);color:#3AB57F"><${D.Icon} name="lock.fill" size=${12} color="#3AB57F" />No account · No cloud · No tracking</div>
      </div>
      ${footer.map(([head, links]) => html`
      <div key=${head} style="display:flex;flex-direction:column;gap:12px;min-width:0">
        <div style="font:600 13px var(--font-sans);color:#fff;margin-bottom:4px">${head}</div>
        ${links.map(([href, label]) => html`<a key=${label} href=${href} class="uo-foot" style="color:rgba(255,255,255,.55);text-decoration:none;font-size:13px">${label}</a>`)}
      </div>`)}
    </div>
    <div style="margin-top:56px;padding-top:24px;box-shadow:inset 0 0.5px 0 rgba(255,255,255,.1);display:flex;flex-direction:column;gap:14px;font-size:11px;line-height:1.6;color:rgba(255,255,255,.55)">
      <p style="margin:0;max-width:none;text-wrap:pretty">Up is a record-keeping app, not a bank, broker or adviser. Prices may be delayed. Nothing here is investment advice.</p>
      <p style="margin:0;max-width:none;text-wrap:pretty">Mac, iPhone and macOS are trademarks of Apple Inc. Other names and logos belong to their owners.</p>
      <div style="display:flex;flex-wrap:wrap;justify-content:space-between;gap:12px;margin-top:6px;font-size:12px"><span>Copyright © 2026 Up</span><span>(The only thing we know about your finances is nothing.)</span></div>
    </div>
  </div>
</footer>
</div>`;
    }
  }

  ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(Site));
})();
