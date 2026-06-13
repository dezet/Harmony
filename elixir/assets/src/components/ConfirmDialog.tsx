import { Loader2 } from "lucide-react"
import { AlertDialog as AlertDialogPrimitive } from "@base-ui/react/alert-dialog"

import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogHeader,
  AlertDialogFooter,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogCancel,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"

export interface ConfirmDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  description?: string
  confirmLabel?: string
  cancelLabel?: string
  onConfirm: () => void
  isPending?: boolean
  destructive?: boolean
}

export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  onConfirm,
  isPending = false,
  destructive = false,
}: ConfirmDialogProps) {
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          {description ? (
            <AlertDialogDescription>{description}</AlertDialogDescription>
          ) : null}
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{cancelLabel}</AlertDialogCancel>
          {isPending ? (
            <Button
              disabled
              variant={destructive ? "destructive" : "default"}
              aria-label="Working…"
            >
              <Loader2 className="animate-spin" />
              {confirmLabel}
            </Button>
          ) : (
            <AlertDialogPrimitive.Close
              render={
                <Button
                  variant={destructive ? "destructive" : "default"}
                  onClick={onConfirm}
                />
              }
            >
              {confirmLabel}
            </AlertDialogPrimitive.Close>
          )}
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
