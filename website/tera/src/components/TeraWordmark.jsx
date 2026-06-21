/** Plain Tera wordmark — no liquid metal / glass shader on the logo itself. */
export function TeraWordmark({ width = 108, height = 40, className = "" }) {
  return (
    <img
      src="/assets/wordmark.svg"
      alt="Tera"
      width={width}
      height={height}
      className={`tera-wordmark ${className}`.trim()}
      decoding="async"
    />
  );
}
