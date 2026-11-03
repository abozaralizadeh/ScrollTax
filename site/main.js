// A little vanilla JS: theme toggle, scroll reveals, the demo video, the toll toy and copy buttons.
(function () {
  var root = document.documentElement;
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // ?static shows everything at once, for screenshots.
  var still = /[?&]static\b/.test(location.search);

  // Theme: follows the system until the visitor picks one.
  var themeBtn = document.getElementById('theme');
  function currentTheme() {
    var set = root.getAttribute('data-theme');
    if (set) return set;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  themeBtn.addEventListener('click', function () {
    var next = currentTheme() === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('scrolltax-theme', next); } catch (e) {}
  });

  // Nav gets a line once you scroll.
  var nav = document.querySelector('.nav');
  function onScroll() { nav.classList.toggle('scrolled', window.scrollY > 8); }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // Scroll reveals.
  var items = document.querySelectorAll('.reveal');
  if (reduce || still || !('IntersectionObserver' in window)) {
    items.forEach(function (el) { el.classList.add('in', 'now'); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    items.forEach(function (el) { io.observe(el); });
  }

  // The demo video loads only once it's on screen. With reduced motion it waits for a tap.
  var video = document.getElementById('demo');
  function loadVideo() {
    if (video.getAttribute('src')) return;
    video.setAttribute('src', video.dataset.src);
    video.playbackRate = 1.25;
    if (reduce) {
      video.controls = true;
    } else {
      video.autoplay = true;
      var p = video.play();
      if (p && p.catch) p.catch(function () { video.controls = true; });
    }
  }
  if ('IntersectionObserver' in window) {
    var vo = new IntersectionObserver(function (entries) {
      if (entries[0].isIntersecting) { loadVideo(); vo.disconnect(); }
    }, { rootMargin: '200px' });
    vo.observe(video);
  } else {
    loadVideo();
  }
  video.addEventListener('loadedmetadata', function () { video.playbackRate = 1.25; });

  // On touch screens there's no hover, so a tap on the phone lifts the hero barrier.
  var stage = document.querySelector('.hero-stage');
  stage.addEventListener('click', function () { stage.classList.toggle('open'); });

  // The toll toy: 15 seconds open per pretend payment, 4 a "day".
  var toll = document.getElementById('toll');
  var pay = document.getElementById('pay');
  var reset = document.getElementById('reset');
  var pill = document.getElementById('toll-pill');
  var count = document.getElementById('toll-count');
  var timer = document.getElementById('toll-timer');
  var ring = document.getElementById('ring-fg');
  var LIMIT = 4, SECONDS = 15, CIRC = 119.4;
  var used = 0, left = 0, tick = null;

  function render() {
    var open = left > 0;
    toll.setAttribute('data-state', open ? 'open' : 'closed');
    pill.textContent = open ? 'Unlocked' : (used >= LIMIT ? 'Blocked till midnight' : 'Blocked');
    count.textContent = used + ' of ' + LIMIT + ' unlocks used today';
    timer.textContent = '0:' + String(open ? left : SECONDS).padStart(2, '0');
    ring.style.strokeDashoffset = open ? String(CIRC * (1 - left / SECONDS)) : '0';
    if (open) {
      pay.disabled = true;
      pay.textContent = 'Unlocked, enjoy the feed';
    } else if (used >= LIMIT) {
      pay.disabled = true;
      pay.textContent = "That's today's 4";
      reset.hidden = false;
    } else {
      pay.disabled = false;
      pay.textContent = 'Pay the pretend toll · 0.99';
    }
  }

  pay.addEventListener('click', function () {
    if (left > 0 || used >= LIMIT) return;
    used += 1;
    left = SECONDS;
    render();
    tick = setInterval(function () {
      left -= 1;
      if (left <= 0) { left = 0; clearInterval(tick); }
      render();
    }, 1000);
  });

  reset.addEventListener('click', function () {
    clearInterval(tick);
    used = 0; left = 0;
    reset.hidden = true;
    render();
    pay.focus();
  });

  render();

  // Copy buttons on the install blocks.
  document.querySelectorAll('.copy').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = document.getElementById(btn.dataset.copy).innerText.trim();
      function done() {
        btn.textContent = 'Copied';
        btn.classList.add('done');
        setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1600);
      }
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
      function fallback() {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); done(); } catch (e) {}
        document.body.removeChild(ta);
      }
    });
  });
})();
