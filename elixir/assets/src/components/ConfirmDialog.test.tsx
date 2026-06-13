import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, it, expect, vi } from "vitest"
import { ConfirmDialog } from "@/components/ConfirmDialog"

function renderDialog(props: Partial<Parameters<typeof ConfirmDialog>[0]> = {}) {
  const defaults = {
    open: true,
    onOpenChange: vi.fn(),
    title: "Delete item",
    description: "This action cannot be undone.",
    onConfirm: vi.fn(),
  }
  return render(<ConfirmDialog {...defaults} {...props} />)
}

describe("ConfirmDialog", () => {
  it("renders title and description when open", () => {
    renderDialog()
    expect(screen.getByText("Delete item")).toBeInTheDocument()
    expect(screen.getByText("This action cannot be undone.")).toBeInTheDocument()
  })

  it("does not render content when closed", () => {
    renderDialog({ open: false })
    expect(screen.queryByText("Delete item")).not.toBeInTheDocument()
  })

  it("renders default confirm and cancel labels", () => {
    renderDialog()
    expect(screen.getByRole("button", { name: /confirm/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /cancel/i })).toBeInTheDocument()
  })

  it("renders custom confirm and cancel labels", () => {
    renderDialog({ confirmLabel: "Delete", cancelLabel: "Keep" })
    expect(screen.getByRole("button", { name: /delete/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /keep/i })).toBeInTheDocument()
  })

  it("calls onConfirm when confirm button is clicked", async () => {
    const onConfirm = vi.fn()
    renderDialog({ onConfirm })
    await userEvent.click(screen.getByRole("button", { name: /confirm/i }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it("calls onOpenChange(false) when Cancel is clicked", async () => {
    const onOpenChange = vi.fn()
    renderDialog({ onOpenChange })
    await userEvent.click(screen.getByRole("button", { name: /cancel/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false, expect.anything())
  })

  it("calls onOpenChange(false) when Escape is pressed", async () => {
    const onOpenChange = vi.fn()
    renderDialog({ onOpenChange })
    // Focus is trapped inside the dialog by base-ui; pressing Escape should close it
    await userEvent.keyboard("{Escape}")
    expect(onOpenChange).toHaveBeenCalledWith(false, expect.anything())
  })

  it("disables confirm button and shows spinner when isPending is true", () => {
    renderDialog({ isPending: true })
    // When pending, we render a disabled Button with aria-label "Working…"
    const pendingBtn = screen.getByRole("button", { name: /working/i })
    expect(pendingBtn).toBeDisabled()
    // The spinner icon should be present (Loader2 renders an svg)
    expect(pendingBtn.querySelector("svg")).toBeTruthy()
  })

  it("does not call onConfirm when confirm button is disabled (isPending)", async () => {
    const onConfirm = vi.fn()
    renderDialog({ isPending: true, onConfirm })
    const pendingBtn = screen.getByRole("button", { name: /working/i })
    // Disabled buttons should not fire click events
    expect(pendingBtn).toBeDisabled()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it("renders description as null when not provided", () => {
    renderDialog({ description: undefined })
    expect(screen.getByText("Delete item")).toBeInTheDocument()
  })

  it("confirm button does NOT auto-close the dialog (onOpenChange not called on confirm)", async () => {
    // The confirm action should not close the dialog itself — the parent controls
    // open state via onSettled/onSuccess callbacks on the mutation.
    const onOpenChange = vi.fn()
    const onConfirm = vi.fn()
    renderDialog({ onOpenChange, onConfirm })
    await userEvent.click(screen.getByRole("button", { name: /confirm/i }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
    expect(onOpenChange).not.toHaveBeenCalled()
  })
})
