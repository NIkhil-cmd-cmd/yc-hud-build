import { useEffect } from "react";

const DOWNLOAD_URL =
  "https://github.com/nook-browser/nook/releases/download/v1.0.2/Nook-v1.0.2.dmg";

const SECTION_IDS = ["about", "highlights", "features", "pricing", "faq"];

export function useSiteEffects() {
  useEffect(() => {
    const nav = document.querySelector(".nav");
    const onScroll = () => {
      if (!nav) return;
      nav.classList.toggle("scrolled", window.scrollY > 40);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    document.querySelectorAll("[data-download]").forEach((el) => {
      el.setAttribute("href", DOWNLOAD_URL);
      el.setAttribute("target", "_blank");
      el.setAttribute("rel", "noopener noreferrer");
    });
  }, []);

  useEffect(() => {
    const revealEls = document.querySelectorAll(".reveal");
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("visible");
            observer.unobserve(entry.target);
          }
        });
      },
      {
        threshold: prefersReduced ? 0 : 0.08,
        rootMargin: prefersReduced ? "0px" : "0px 0px -8% 0px",
      }
    );
    revealEls.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    requestAnimationFrame(() => {
      document.querySelectorAll(".hero-stagger").forEach((el, i) => {
        setTimeout(() => el.classList.add("visible"), 80 * i);
      });
    });
  }, []);
}

export function useScrollChrome() {
  useEffect(() => {
    const bar = document.querySelector(".scroll-progress-bar");
    const heroStack = document.querySelector(".hero-shader-stack");
    const backToTop = document.querySelector(".back-to-top");
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const onScroll = () => {
      const scrollTop = window.scrollY;
      const docHeight = document.documentElement.scrollHeight - window.innerHeight;
      const progress = docHeight > 0 ? Math.min(1, scrollTop / docHeight) : 0;

      if (bar) bar.style.transform = `scaleX(${progress})`;

      if (heroStack && !prefersReduced) {
        const hero = document.querySelector(".hero");
        const heroHeight = hero?.offsetHeight ?? window.innerHeight;
        const t = Math.min(1, scrollTop / heroHeight);
        heroStack.style.setProperty("--hero-scroll", String(t));
      }

      if (backToTop) {
        backToTop.classList.toggle("visible", scrollTop > window.innerHeight * 0.65);
      }
    };

    backToTop?.addEventListener("click", () => {
      window.scrollTo({ top: 0, behavior: prefersReduced ? "auto" : "smooth" });
    });

    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
    return () => window.removeEventListener("scroll", onScroll);
  }, []);
}

export function useActiveSectionNav() {
  useEffect(() => {
    const links = document.querySelectorAll(".nav-links a[data-section], .section-jump a[data-section]");
    if (links.length === 0) return;

    const sections = SECTION_IDS.map((id) => document.getElementById(id)).filter(Boolean);
    if (sections.length === 0) return;

    const setActive = (id) => {
      links.forEach((link) => {
        link.classList.toggle("active", link.getAttribute("data-section") === id);
      });
    };

    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((e) => e.isIntersecting)
          .sort((a, b) => b.intersectionRatio - a.intersectionRatio);
        if (visible[0]?.target?.id) setActive(visible[0].target.id);
      },
      { rootMargin: "-35% 0px -45% 0px", threshold: [0, 0.15, 0.4] }
    );

    sections.forEach((section) => observer.observe(section));
    return () => observer.disconnect();
  }, []);
}

export function useMockupCarousel() {
  useEffect(() => {
    let slideIndex = 0;
    const slides = document.querySelector(".browser-slides");
    const dots = document.querySelectorAll(".mockup-dot");
    const notch = document.querySelector(".notch-overlay");
    if (!slides || dots.length === 0) return;

    const goTo = (i) => {
      slideIndex = i;
      slides.style.transform = `translateX(-${i * 100}%)`;
      dots.forEach((d, j) => {
        d.classList.toggle("active", j === i);
        d.setAttribute("aria-selected", j === i ? "true" : "false");
      });
      notch?.classList.toggle("visible", i === 1);
    };

    dots.forEach((dot, i) => dot.addEventListener("click", () => goTo(i)));
    const timer = setInterval(() => goTo((slideIndex + 1) % dots.length), 5000);
    return () => clearInterval(timer);
  }, []);
}

export function useTestimonialCarousel() {
  useEffect(() => {
    let idx = 0;
    const slides = document.querySelectorAll(".testimonial-slide");
    const prev = document.querySelector(".testimonial-prev");
    const next = document.querySelector(".testimonial-next");
    if (slides.length === 0) return;

    const show = (i) => {
      slides.forEach((s, j) => s.classList.toggle("active", j === i));
      idx = i;
    };

    prev?.addEventListener("click", () => show((idx - 1 + slides.length) % slides.length));
    next?.addEventListener("click", () => show((idx + 1) % slides.length));
    const timer = setInterval(() => show((idx + 1) % slides.length), 5000);
    return () => clearInterval(timer);
  }, []);
}

export function useAccordions() {
  useEffect(() => {
    const featureCards = document.querySelectorAll(".feature-card");
    featureCards.forEach((card) => {
      const header = card.querySelector(".feature-card-header");
      header?.addEventListener("click", () => {
        const wasOpen = card.classList.contains("open");
        featureCards.forEach((c) => {
          c.classList.remove("open");
          c.querySelector(".feature-toggle").textContent = "Info";
        });
        if (!wasOpen) {
          card.classList.add("open");
          card.querySelector(".feature-toggle").textContent = "Close";
        }
      });
    });

    document.querySelectorAll(".faq-item").forEach((item) => {
      const btn = item.querySelector(".faq-question");
      btn?.addEventListener("click", () => {
        const wasOpen = item.classList.contains("open");
        document.querySelectorAll(".faq-item.open").forEach((i) => i.classList.remove("open"));
        if (!wasOpen) item.classList.add("open");
      });
    });

    document.querySelectorAll(".waitlist-form").forEach((form) => {
      form.addEventListener("submit", (e) => {
        e.preventDefault();
        const input = form.querySelector("input[type=email]");
        const msg = form.querySelector(".form-msg");
        if (input?.value && msg) {
          msg.textContent = "You are on the waitlist. We will be in touch.";
          input.value = "";
        }
      });
    });
  }, []);
}

export function useMobileMenu() {
  useEffect(() => {
    const toggle = document.querySelector(".menu-toggle");
    const overlay = document.querySelector(".nav-overlay");
    if (!toggle || !overlay) return;

    const close = () => {
      overlay.classList.remove("open");
      toggle.classList.remove("active");
      document.body.classList.remove("menu-open");
    };

    toggle.addEventListener("click", () => {
      const open = overlay.classList.toggle("open");
      toggle.classList.toggle("active", open);
      document.body.classList.toggle("menu-open", open);
    });
    overlay.querySelectorAll("a").forEach((a) => a.addEventListener("click", close));
  }, []);
}
