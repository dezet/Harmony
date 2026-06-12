// Deliberately a raw dump: the payload shape is untyped (`unknown`) until the
// contract defines it. Phase 5 replaces this with a designed rate-limit view.
export function RateLimits({ value }: { value: unknown }) {
  return (
    <pre className="text-xs bg-muted p-3 rounded-md overflow-auto">
      {JSON.stringify(value ?? null, null, 2)}
    </pre>
  );
}
