import { ShaderBackground, TESTIMONIALS_GRADIENT } from "./components/ShaderBackground.jsx";
import { TeraWordmark } from "./components/TeraWordmark.jsx";
import { LiquidGlass } from "./components/LiquidGlass.jsx";
import { GrainCardArt } from "./components/GrainCardArt.jsx";
import {
  useSiteEffects,
  useMockupCarousel,
  useTestimonialCarousel,
  useAccordions,
  useMobileMenu,
} from "./hooks/useSiteEffects.js";

const HIGHLIGHTS = [
  {
    tags: ["Demo", "Zero tokens"],
    title: "Flight booking",
    body: "Learn once from a single demonstration. Replay in roughly fifteen seconds with zero tokens on the second run.",
  },
  {
    tags: ["Observation", "Local"],
    title: "Passive learning",
    body: "Every click becomes training data — silently, in the background, without an explicit record mode.",
  },
  {
    tags: ["Agent-first", "In-tab"],
    title: "Agent-first tab",
    body: "Type a task in a new tab and the agent runs in your current window — no external browser required.",
  },
  {
    tags: ["MDP", "Visual"],
    title: "Workflow graph",
    body: "See the Markov policy your browsing compiled — states, transitions, and replay paths made visible.",
  },
];

const TESTIMONIALS = [
  {
    quote:
      "Run 2: zero tokens, fifteen seconds. Browser Use baseline: fifteen thousand tokens, sixty-eight seconds — every single time.",
    initials: "HUD",
    name: "Benchmark result",
    role: "Repeat workflow evaluation",
  },
  {
    quote:
      "The browser is the environment. You are the expert. Your actions are demonstrations — Tera just remembers them.",
    initials: "RL",
    name: "Policy engine",
    role: "Embedding-based MDP",
  },
  {
    quote:
      "Nothing leaves your Mac. Workflows compile on-device from observed actions. No upload model, no cloud training pipeline.",
    initials: "LK",
    name: "Local-first",
    role: "Privacy by architecture",
  },
  {
    quote:
      "Type a task, not a URL. The new tab is a prompt bar — the agent runs in the same tab you already have open.",
    initials: "AT",
    name: "Agent-first UX",
    role: "Native WKWebView",
  },
];

const FEATURES = [
  {
    title: "Passive Learning",
    body: "Tera observes your actions silently as you browse. No explicit record mode, no interruption — every click and navigation becomes training data in the background.",
  },
  {
    title: "Zero-Token Replay",
    body: "Repeat tasks execute via embedding-based policy lookup. When state matches, the MDP replays your workflow with zero LLM tokens — measured from API usage fields.",
  },
  {
    title: "Agent-First Tab",
    body: "The new tab is a task prompt, not a blank page. Type what you need done and the agent runs natively in your WKWebView tab — one browser, no external Chrome.",
  },
  {
    title: "Local-Only Data",
    body: "Workflows, policies, and observation logs stay in ~/Library/Application Support/OpenHive/. Nothing is uploaded. Your data is never sold or used to build ad profiles.",
  },
];

const FAQ = [
  {
    q: "How does passive learning work?",
    a: "Tera injects a lightweight observer into each tab's WebView. As you browse, actions are captured and sent to the local Python policy engine over a WebSocket bridge. There is no explicit record button — observation is always on.",
  },
  {
    q: "Where is my data stored?",
    a: "All workflows, policies, and metrics live locally at ~/Library/Application Support/OpenHive/. Nothing is uploaded to a cloud training pipeline. Your browsing data stays on your Mac.",
  },
  {
    q: "What are zero-token replays?",
    a: "After one learning session, repeat runs match against an embedding-based Markov policy. When the current page state matches a known state, Tera executes the stored action without calling an LLM.",
  },
  {
    q: "How is Tera different from Browser Use or Dia?",
    a: "Browser Use drives external Chrome via Playwright — roughly fifteen thousand tokens per run. Tera runs natively in WKWebView and replays learned workflows with zero tokens. Dia focuses on proactive suggestions; Tera compiles and replays your exact browsing workflows locally.",
  },
  {
    q: "What models are supported?",
    a: "The agent supports configurable models via Fireworks, OpenAI, and other providers configured in your local .env file. Policy replay uses no model at all.",
  },
  {
    q: "Do I need the Python engine running?",
    a: "Yes, for agent tasks and workflow compilation. Start it with ./scripts/start_engine.sh — it listens on ws://127.0.0.1:8765.",
  },
  {
    q: "What are the macOS requirements?",
    a: "Tera requires macOS 15.5 or later. Built with Swift 6, SwiftUI, and native WebKit.",
  },
  {
    q: "Is Tera open source?",
    a: "Tera is built on Nook, a GPL-3.0 licensed macOS browser. Source is available on GitHub.",
  },
];

const STACK = ["Swift", "WebKit", "Python", "HUD", "Exa", "Fireworks", "MCP", "NetworkX"];

export default function App() {
  useSiteEffects();
  useMockupCarousel();
  useTestimonialCarousel();
  useAccordions();
  useMobileMenu();

  return (
    <>
      <header className="nav" role="banner">
        <LiquidGlass className="nav-glass" as="div" intensity={0.85} blur={26}>
          <div className="nav-inner">
            <a href="#" className="nav-logo-link" aria-label="Tera home">
              <TeraWordmark width={96} height={36} />
            </a>
            <div className="nav-right">
              <span className="nav-badge">macOS 15.5+</span>
              <nav className="nav-links" aria-label="Primary">
                <a href="#features">Features</a>
                <a href="#pricing">Pricing</a>
                <a href="/privacy.html">Privacy</a>
              </nav>
              <a href="#" className="btn btn-primary" data-download>
                Download
              </a>
              <button className="menu-toggle" aria-label="Open menu" type="button">
                <span />
                <span />
                <span />
              </button>
            </div>
          </div>
        </LiquidGlass>
      </header>

      <nav className="nav-overlay" aria-label="Mobile menu" aria-hidden="true">
        <a href="#">Home</a>
        <a href="#features">Features</a>
        <a href="#pricing">Pricing</a>
        <a href="/privacy.html">Privacy</a>
      </nav>

      <main>
        <section className="hero" aria-labelledby="hero-heading">
          <ShaderBackground className="hero-shader" pixelDensity={1.8} />
          <div className="container hero-content">
            <div className="hero-logo-wrap reveal hero-stagger">
              <TeraWordmark width={180} height={64} />
            </div>
            <h1 id="hero-heading" className="display reveal hero-stagger reveal-delay-1">
              The agent thought once.
              <br />
              Now it never has to again.
            </h1>
            <p className="hero-sub reveal hero-stagger reveal-delay-2">
              Tera learns from how you browse, compiles your workflows on-device, and replays them without calling an LLM again.
            </p>
          </div>
        </section>

        <section className="section" id="about" aria-labelledby="about-heading">
          <div className="container about-grid">
            <div className="about-text reveal">
              <p className="section-label">About Tera</p>
              <h2 id="about-heading" className="display">
                We craft a browser that turns everyday browsing into workflows you trust.
              </h2>
              <p className="body-lg about-lead">
                Tera is a research-driven macOS browser built on native WebKit. It passively observes how you work, compiles an embedding-based policy on your machine, and replays repeat tasks with zero LLM tokens when state matches.
              </p>
              <p className="body-lg">
                All training data stays local. Nothing is sent to a cloud training pipeline. Your workflows live in your Library folder, under your control.
              </p>
              <a href="#features" className="link-arrow">
                See how it works
              </a>
            </div>
            <LiquidGlass className="about-panel reveal reveal-delay-1" intensity={0.7} blur={18}>
              <div className="about-panel-inner">
                <p className="about-stat">0</p>
                <p className="about-stat-label">tokens on replay</p>
                <p className="about-stat-sub">Measured from API usage — not estimated.</p>
              </div>
            </LiquidGlass>
          </div>
        </section>

        <section className="mockup-section" aria-label="Browser preview">
          <div className="container mockup-wrap reveal">
            <LiquidGlass className="browser-frame" intensity={0.6} blur={20}>
              <div className="browser-frame-inner">
                <div className="browser-slides">
                  <div className="browser-slide">
                    <img src="/assets/screenshots/agent-home.svg" alt="Tera agent-first new tab" width="960" height="600" />
                  </div>
                  <div className="browser-slide">
                    <img src="/assets/screenshots/workflow-graph.svg" alt="Tera workflow policy graph" width="960" height="600" />
                  </div>
                  <div className="browser-slide">
                    <img src="/assets/screenshots/agent-home.svg" alt="Tera browsing view" width="960" height="600" />
                  </div>
                </div>
                <div className="notch-overlay" aria-hidden="true">
                  <img src="/assets/screenshots/agent-notch.svg" alt="" width="400" height="80" />
                </div>
              </div>
            </LiquidGlass>
            <div className="mockup-dots" role="tablist" aria-label="Preview slides">
              <button className="mockup-dot active" type="button" role="tab" aria-selected="true" aria-label="Slide 1" />
              <button className="mockup-dot" type="button" role="tab" aria-selected="false" aria-label="Slide 2" />
              <button className="mockup-dot" type="button" role="tab" aria-selected="false" aria-label="Slide 3" />
            </div>
          </div>
        </section>

        <section className="section" id="highlights" aria-labelledby="highlights-heading">
          <div className="container">
            <div className="highlights-header reveal">
              <p className="section-label">Our highlights</p>
              <h2 id="highlights-heading" className="display">
                Workflows that stick.
                <br />
                Runs that cost nothing.
              </h2>
              <p className="body-lg highlights-lead">
                Explore how Tera turns everyday browsing into repeatable, zero-token automation.
              </p>
            </div>
            <div className="highlights-grid">
              {HIGHLIGHTS.map((item, i) => (
                <article key={item.title} className={`highlight-card reveal${i % 2 ? " reveal-delay-1" : ""}`}>
                  <div className="highlight-card-image">
                    <GrainCardArt index={i} />
                  </div>
                  <div className="highlight-card-body">
                    <div className="highlight-tags">
                      {item.tags.map((t) => (
                        <span key={t} className="highlight-tag">
                          {t}
                        </span>
                      ))}
                    </div>
                    <h3>{item.title}</h3>
                    <p>{item.body}</p>
                  </div>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className="section testimonials" aria-labelledby="testimonials-heading">
          <ShaderBackground
            urlString={TESTIMONIALS_GRADIENT}
            className="testimonials-shader"
            pixelDensity={1.2}
            variant="testimonials"
          />
          <div className="container testimonials-inner">
            <p className="section-label reveal">Trusted by builders</p>
            <h2 id="testimonials-heading" className="display reveal">
              Why teams rely on Tera
            </h2>
            <div className="testimonial-carousel reveal">
              {TESTIMONIALS.map((t, i) => (
                <blockquote key={t.initials} className={`testimonial-slide${i === 0 ? " active" : ""}`}>
                  <p className="testimonial-quote">{t.quote}</p>
                  <footer className="testimonial-author">
                    <div className="testimonial-avatar" aria-hidden="true">
                      {t.initials}
                    </div>
                    <div className="testimonial-meta">
                      <strong>{t.name}</strong>
                      {t.role}
                    </div>
                  </footer>
                </blockquote>
              ))}
              <div className="testimonial-nav">
                <button className="testimonial-prev" type="button" aria-label="Previous testimonial">
                  &#8592;
                </button>
                <button className="testimonial-next" type="button" aria-label="Next testimonial">
                  &#8594;
                </button>
              </div>
            </div>
          </div>
        </section>

        <section className="marquee-section" aria-labelledby="marquee-heading">
          <div className="marquee-header">
            <h2 id="marquee-heading">Our stack &amp; your workflows.</h2>
          </div>
          <div className="marquee-track-wrap" aria-hidden="true">
            <div className="marquee-track">
              {[...STACK, ...STACK].map((item, i) => (
                <span key={`${item}-${i}`} className="marquee-item">
                  {item}
                </span>
              ))}
            </div>
          </div>
        </section>

        <section className="section" id="features" aria-labelledby="features-heading">
          <div className="container">
            <div className="reveal features-intro">
              <p className="section-label">Capabilities</p>
              <h2 id="features-heading" className="display">
                Built for how you actually browse
              </h2>
              <p className="body-lg">
                From passive observation to zero-token replay — every layer stays on your machine.
              </p>
            </div>
            <div className="features-grid">
              {FEATURES.map((f, i) => (
                <LiquidGlass
                  key={f.title}
                  className={`feature-card reveal${i % 2 ? " reveal-delay-1" : ""}`}
                  intensity={0.55}
                  blur={16}
                >
                  <button className="feature-card-header" type="button" aria-expanded="false">
                    <h3>{f.title}</h3>
                    <span className="feature-toggle">Info</span>
                  </button>
                  <div className="feature-body">
                    <p>{f.body}</p>
                  </div>
                </LiquidGlass>
              ))}
            </div>
          </div>
        </section>

        <section className="section pricing-section" id="pricing" aria-labelledby="pricing-heading">
          <div className="container">
            <div className="pricing-header reveal">
              <p className="section-label">Choose your pace</p>
              <h2 id="pricing-heading" className="display">
                Ongoing partnership or focused start
              </h2>
            </div>
            <div className="pricing-grid">
              <LiquidGlass className="pricing-card reveal" intensity={0.5} blur={14}>
                <img className="pricing-keycap" src="/assets/keycap-ember.svg" alt="" width="200" height="220" />
                <p className="pricing-tier">Free</p>
                <p className="pricing-price">$0</p>
                <p className="pricing-period">forever</p>
                <ul className="pricing-features">
                  <li>Core browser</li>
                  <li>Passive learning</li>
                  <li>Local workflow storage</li>
                  <li>Agent-first new tab</li>
                </ul>
                <a href="#" className="btn btn-primary btn-block" data-download>
                  Download
                </a>
              </LiquidGlass>
              <LiquidGlass className="pricing-card reveal reveal-delay-1" intensity={0.5} blur={14}>
                <img className="pricing-keycap" src="/assets/keycap-moss.svg" alt="" width="200" height="220" />
                <p className="pricing-tier">Pro</p>
                <p className="pricing-price">Waitlist</p>
                <p className="pricing-period">coming soon</p>
                <ul className="pricing-features">
                  <li>Advanced model routing</li>
                  <li>MCP integrations</li>
                  <li>Priority agent scheduling</li>
                  <li>Extended workflow library</li>
                </ul>
                <form className="waitlist-form" aria-label="Pro waitlist">
                  <input type="email" name="email" placeholder="you@company.com" required autoComplete="email" />
                  <button type="submit">Join waitlist</button>
                  <span className="form-msg" role="status" aria-live="polite" />
                </form>
              </LiquidGlass>
              <LiquidGlass className="pricing-card reveal reveal-delay-2" intensity={0.5} blur={14}>
                <img className="pricing-keycap" src="/assets/keycap-slate.svg" alt="" width="200" height="220" />
                <p className="pricing-tier">Team</p>
                <p className="pricing-price">Custom</p>
                <p className="pricing-period">contact us</p>
                <ul className="pricing-features">
                  <li>SSO and admin tools</li>
                  <li>Shared workflow policies</li>
                  <li>Team guardrails</li>
                  <li>Dedicated support</li>
                </ul>
                <form className="waitlist-form" aria-label="Team waitlist">
                  <input type="email" name="email" placeholder="team@company.com" required autoComplete="email" />
                  <button type="submit">Request access</button>
                  <span className="form-msg" role="status" aria-live="polite" />
                </form>
              </LiquidGlass>
            </div>
            <p className="pricing-note reveal">Pause anytime. No long-term contracts. Pro and Team tiers opening in sequence.</p>
          </div>
        </section>

        <section className="section" id="faq" aria-labelledby="faq-heading">
          <div className="container">
            <div className="reveal faq-header">
              <p className="section-label">FAQ</p>
              <h2 id="faq-heading" className="display">
                Frequently asked questions
              </h2>
            </div>
            <div className="faq-list reveal">
              {FAQ.map((item) => (
                <div key={item.q} className="faq-item">
                  <button className="faq-question" type="button" aria-expanded="false">
                    {item.q}
                    <span className="faq-icon" aria-hidden="true" />
                  </button>
                  <div className="faq-answer">
                    <div className="faq-answer-inner">{item.a}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>
      </main>

      <footer className="footer" role="contentinfo">
        <div className="container">
          <div className="footer-hero">
            <TeraWordmark width={140} height={52} className="footer-logo" />
            <h2>
              The agent thought once.
              <br />
              Now it never has to again.
            </h2>
            <a href="#" className="btn btn-outline footer-cta" data-download>
              Download Tera
            </a>
          </div>
          <div className="footer-grid">
            <div className="footer-links">
              <h4>Explore</h4>
              <a href="#">Home</a>
              <a href="#features">Features</a>
              <a href="#pricing">Pricing</a>
              <a href="/privacy.html">Privacy</a>
            </div>
            <div className="footer-links">
              <h4>Project</h4>
              <a href="https://github.com/nook-browser/Nook" target="_blank" rel="noopener noreferrer">
                GitHub
              </a>
              <a href="https://github.com/nook-browser/nook/releases" target="_blank" rel="noopener noreferrer">
                Releases
              </a>
            </div>
          </div>
          <div className="footer-bottom">
            <span>2026 Tera. All rights reserved.</span>
            <span>
              <a href="/privacy.html">Privacy</a>
            </span>
          </div>
        </div>
      </footer>
    </>
  );
}
