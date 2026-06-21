(function () {
  "use strict";

  const DOWNLOAD_URL =
    "https://github.com/nook-browser/nook/releases/download/v1.0.2/Nook-v1.0.2.dmg";

  // Nav scroll + menu
  const nav = document.querySelector(".nav");
  const menuToggle = document.querySelector(".menu-toggle");
  const navOverlay = document.querySelector(".nav-overlay");

  function onScroll() {
    if (window.scrollY > 40) nav.classList.add("scrolled");
    else nav.classList.remove("scrolled");

    // Hero parallax
    const heroImg = document.querySelector(".hero-bg img");
    if (heroImg && window.innerWidth >= 810) {
      const offset = window.scrollY * 0.35;
      heroImg.style.transform = `translateY(${offset}px)`;
    }

    // Mockup parallax
    const frame = document.querySelector(".browser-frame");
    if (frame) {
      const rect = frame.getBoundingClientRect();
      const center = rect.top + rect.height / 2 - window.innerHeight / 2;
      frame.style.transform = `translateY(${center * -0.08}px)`;
    }
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  menuToggle?.addEventListener("click", () => {
    const open = navOverlay.classList.toggle("open");
    menuToggle.classList.toggle("active", open);
    document.body.classList.toggle("menu-open", open);
  });

  navOverlay?.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => {
      navOverlay.classList.remove("open");
      menuToggle.classList.remove("active");
      document.body.classList.remove("menu-open");
    });
  });

  // Scroll reveal
  const revealEls = document.querySelectorAll(".reveal");
  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          revealObserver.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
  );
  revealEls.forEach((el) => revealObserver.observe(el));

  // Hero load stagger
  requestAnimationFrame(() => {
    document.querySelectorAll(".hero-stagger").forEach((el, i) => {
      setTimeout(() => el.classList.add("visible"), 80 * i);
    });
  });

  // Browser mockup carousel
  let slideIndex = 0;
  const slides = document.querySelector(".browser-slides");
  const dots = document.querySelectorAll(".mockup-dot");
  const notch = document.querySelector(".notch-overlay");
  const totalSlides = dots.length;

  function goToSlide(i) {
    slideIndex = i;
    if (slides) slides.style.transform = `translateX(-${i * 100}%)`;
    dots.forEach((d, j) => d.classList.toggle("active", j === i));
    if (notch) notch.classList.toggle("visible", i === 1);
  }

  dots.forEach((dot, i) => dot.addEventListener("click", () => goToSlide(i)));

  setInterval(() => {
    goToSlide((slideIndex + 1) % totalSlides);
  }, 5000);

  // Testimonial carousel
  let testimonialIndex = 0;
  const testimonialSlides = document.querySelectorAll(".testimonial-slide");
  const prevBtn = document.querySelector(".testimonial-prev");
  const nextBtn = document.querySelector(".testimonial-next");

  function showTestimonial(i) {
    testimonialSlides.forEach((s, j) => s.classList.toggle("active", j === i));
    testimonialIndex = i;
  }

  prevBtn?.addEventListener("click", () => {
    showTestimonial(
      (testimonialIndex - 1 + testimonialSlides.length) % testimonialSlides.length
    );
  });

  nextBtn?.addEventListener("click", () => {
    showTestimonial((testimonialIndex + 1) % testimonialSlides.length);
  });

  setInterval(() => {
    showTestimonial((testimonialIndex + 1) % testimonialSlides.length);
  }, 5000);

  // Feature accordion
  document.querySelectorAll(".feature-card").forEach((card) => {
    const header = card.querySelector(".feature-card-header");
    header?.addEventListener("click", () => {
      const wasOpen = card.classList.contains("open");
      document.querySelectorAll(".feature-card.open").forEach((c) => {
        c.classList.remove("open");
        c.querySelector(".feature-toggle").textContent = "Info";
      });
      if (!wasOpen) {
        card.classList.add("open");
        card.querySelector(".feature-toggle").textContent = "Close";
      }
    });
  });

  // FAQ accordion
  document.querySelectorAll(".faq-item").forEach((item) => {
    const btn = item.querySelector(".faq-question");
    btn?.addEventListener("click", () => {
      const wasOpen = item.classList.contains("open");
      document.querySelectorAll(".faq-item.open").forEach((i) => i.classList.remove("open"));
      if (!wasOpen) item.classList.add("open");
    });
  });

  // Waitlist forms (local-only until backend wired)
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

  // Download links
  document.querySelectorAll("[data-download]").forEach((el) => {
    el.setAttribute("href", DOWNLOAD_URL);
    el.setAttribute("target", "_blank");
    el.setAttribute("rel", "noopener noreferrer");
  });
})();
