export function RateLimits({ value }: { value: unknown }) {
  return (
    <pre className="text-xs bg-muted p-3 rounded-md overflow-auto">
      {JSON.stringify(value ?? null, null, 2)}
    </pre>
  );
}
