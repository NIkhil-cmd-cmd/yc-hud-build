/** Fixed scroll progress bar at top of viewport */
export function ScrollProgress() {
  return (
    <div className="scroll-progress" aria-hidden="true">
      <div className="scroll-progress-bar" />
    </div>
  );
}

/** Back-to-top control — shown after scrolling past hero */
export function BackToTop() {
  return (
    <button type="button" className="back-to-top" aria-label="Back to top">
      <span aria-hidden="true">↑</span>
    </button>
  );
}
