import { useId, useState, type FormEvent } from "react";
import { Dialog } from "@base-ui/react/dialog";
import { CircleCheck, Loader2, Send, TriangleAlert, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { integrationErrorMessage, useTestSend } from "@/features/integrations/useIntegrations";
import type { IntegrationConnection } from "@/types/contract";

// „Wyślij test” (spec §4.6, §10.4, §11.2): a real, possibly paid message to
// one recipient, only after an explicit cost confirmation. Each attempt has
// its own Idempotency-Key (UUID): created when the dialog opens, kept while
// the same attempt is repeated after an unknown outcome, replaced for another
// recipient or a new attempt. So a double click or a retry never queues a
// second message. The backend accepts the message into its outbox; that is
// not a proof of delivery.

const input =
  "w-full min-w-0 rounded-[6px] border bg-background px-[11px] py-2.5 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/50 aria-invalid:border-destructive";
const actionButton =
  "h-auto min-h-[35px] gap-[7px] rounded-[7px] px-3 py-[9px] text-[11px] font-[550] leading-[1.3] max-[600px]:flex-1 [&_svg:not([class*='size-'])]:size-3.5";

const ADDRESS = /^[A-Za-z0-9._%+'-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/;
// E.164 with the country prefix (+ or 00); spaces, dashes, dots and brackets are separators.
const PHONE = /^(?:\+|00)[1-9][0-9]{6,14}$/;

function newKey(): string {
  return crypto.randomUUID();
}

function recipientError(sms: boolean, value: string): string | null {
  const trimmed = value.trim();
  if (sms) {
    return PHONE.test(trimmed.replace(/[\s().-]/g, ""))
      ? null
      : "Podaj numer z prefiksem kraju, np. +48 600 100 200.";
  }
  return ADDRESS.test(trimmed) ? null : "Podaj adres e-mail odbiorcy, np. dyzur@example.com.";
}

function TestDeliveryForm({ connection }: { connection: IntegrationConnection }) {
  const prefix = useId();
  const sms = connection.kind === "smsapi";
  const send = useTestSend(connection.id);
  const [recipient, setRecipient] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [attempt, setAttempt] = useState(() => ({ key: newKey(), recipient: null as string | null }));

  const recipientId = `${prefix}-recipient`;
  const confirmId = `${prefix}-confirm`;
  const error = submitted ? recipientError(sms, recipient) : null;
  const confirmError = submitted && !confirmed ? "Potwierdź koszt i wysłanie prawdziwej wiadomości." : null;

  const onSubmit = (event: FormEvent) => {
    event.preventDefault();
    setSubmitted(true);
    if (recipientError(sms, recipient) || !confirmed || send.isPending) return;
    const value = recipient.trim();
    // Same recipient = the same attempt, repeated with its key; another one is a new attempt.
    const key = attempt.recipient === null || attempt.recipient === value ? attempt.key : newKey();
    setAttempt({ key, recipient: value });
    send.mutate({ recipient: value, idempotencyKey: key });
  };

  const newAttempt = () => {
    send.reset();
    setAttempt({ key: newKey(), recipient: null });
    setConfirmed(false);
    setSubmitted(false);
  };

  if (send.isSuccess) {
    return (
      <div className="grid gap-4">
        <p role="status" className="flex items-start gap-2 rounded-[8px] border bg-success-surface p-[15px] text-[11px] leading-[1.8] text-success">
          <CircleCheck aria-hidden className="mt-0.5 size-4 shrink-0" strokeWidth={1.6} />
          <span>
            Przyjęto do wysłania: wiadomość testowa do {attempt.recipient} czeka w kolejce Harmony. To nie oznacza doręczenia —
            {sms ? " SMSAPI potwierdza tylko przyjęcie." : " serwer SMTP potwierdza tylko przyjęcie."}
          </span>
        </p>
        <div className="flex flex-wrap justify-end gap-2.5">
          <Button type="button" variant="outline" className={cn(actionButton, "bg-card")} onClick={newAttempt}>
            Nowa próba
          </Button>
          <Dialog.Close render={<Button type="button" className={actionButton} />}>Zamknij</Dialog.Close>
        </div>
      </div>
    );
  }

  return (
    <form noValidate onSubmit={onSubmit} className="grid gap-4">
      <div className="grid gap-2 rounded-[7px] border bg-background p-3 text-[11px] leading-[1.7] text-muted-foreground">
        {sms ? (
          <>
            <p>
              <strong className="font-semibold text-foreground">Koszt: jeden płatny SMS</strong> według cennika Twojego konta
              SMSAPI. Treść testowa mieści się w jednym segmencie; prawdziwy alert może zająć do dwóch.
            </p>
            <p>Wiadomość wlicza się do limitu 20 SMS na godzinę dla tego połączenia.</p>
          </>
        ) : (
          <>
            <p>
              <strong className="font-semibold text-foreground">Zostanie wysłany prawdziwy e-mail</strong> z nadawcą tego
              połączenia, bez danych żadnej sprawy.
            </p>
            <p>Wiadomość wlicza się do limitu 60 e-maili na godzinę dla tego połączenia.</p>
          </>
        )}
      </div>

      <div className="flex min-w-0 flex-col gap-2 text-[11px]">
        <label htmlFor={recipientId}>{sms ? "Numer telefonu odbiorcy" : "Adres e-mail odbiorcy"}</label>
        <input
          id={recipientId}
          type={sms ? "tel" : "email"}
          autoComplete="off"
          className={input}
          value={recipient}
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? `${recipientId}-error` : undefined}
          onChange={(event) => setRecipient(event.target.value)}
        />
        {error ? (
          <span id={`${recipientId}-error`} className="text-[10px] leading-[1.6] text-destructive">
            {error}
          </span>
        ) : null}
      </div>

      <div className="grid gap-1">
        <label className="flex items-start gap-2 text-[11px] leading-[1.6]">
          <input
            id={confirmId}
            type="checkbox"
            className="mt-0.5 size-[15px] accent-primary"
            checked={confirmed}
            aria-invalid={confirmError ? true : undefined}
            aria-describedby={confirmError ? `${confirmId}-error` : undefined}
            onChange={(event) => setConfirmed(event.target.checked)}
          />
          {sms
            ? "Potwierdzam wysłanie prawdziwego, płatnego SMS-a na ten numer."
            : "Potwierdzam wysłanie prawdziwej wiadomości e-mail na ten adres."}
        </label>
        {confirmError ? (
          <span id={`${confirmId}-error`} className="text-[10px] leading-[1.6] text-destructive">
            {confirmError}
          </span>
        ) : null}
      </div>

      {send.isError ? (
        <p role="alert" className="flex items-start gap-1.5 text-[11px] leading-[1.5] text-destructive">
          <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
          {integrationErrorMessage(send.error)}
        </p>
      ) : null}

      <div className="flex flex-wrap justify-end gap-2.5">
        <Dialog.Close render={<Button type="button" variant="outline" className={cn(actionButton, "bg-card")} />}>
          Anuluj
        </Dialog.Close>
        <Button type="submit" className={actionButton} disabled={send.isPending}>
          {send.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : <Send aria-hidden />}
          Wyślij test
        </Button>
      </div>
    </form>
  );
}

export interface TestDeliveryDialogProps {
  connection: IntegrationConnection | null;
  onClose: () => void;
}

/** Focus-trapped by the Base UI dialog; the form (and its key) is new on every opening. */
export function TestDeliveryDialog({ connection, onClose }: TestDeliveryDialogProps) {
  return (
    <Dialog.Root open={connection !== null} onOpenChange={(open) => (open ? undefined : onClose())}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-40 bg-[#11131e88] backdrop-blur-[3px] transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 flex max-h-[90vh] w-[min(520px,calc(100vw-30px))] -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-[13px] border bg-card text-foreground shadow-[0_25px_100px_#0005] outline-none transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none">
          <div className="flex shrink-0 items-center justify-between gap-3 border-b px-5 py-3">
            <div className="min-w-0">
              <Dialog.Title className="text-[14px] font-semibold">Wyślij wiadomość testową</Dialog.Title>
              {connection ? (
                <Dialog.Description className="mt-0.5 text-[11px] text-muted-foreground">{connection.name}</Dialog.Description>
              ) : null}
            </div>
            <Dialog.Close
              aria-label="Zamknij okno"
              className="inline-flex rounded-[5px] p-[7px] text-foreground outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/50"
            >
              <X aria-hidden className="size-4" strokeWidth={1.6} />
            </Dialog.Close>
          </div>
          <div className="overflow-y-auto p-5">{connection ? <TestDeliveryForm connection={connection} /> : null}</div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
