/**
 * Orkiestra Accessibility & Keyboard Navigation Module
 * Implements WAI-ARIA Authoring Practices (APG) keyboard patterns:
 * - Roving tabindex for Tabs, RadioGroups, Toolbars, and Navigation
 * - Modal Dialog focus trapping and focus restoration
 * - Menu Button (aria-haspopup="menu") keyboard navigation
 * - Switch (role="switch"), Toggle (aria-pressed), and Spinbutton steppers
 * - Sortable Data Table (aria-sort) with live announcements
 * - Accessible Form Validation (aria-invalid, aria-describedby, role="alert")
 * - Global keyboard shortcuts (/, ?, Alt+N, Alt+1..4)
 */

(function () {
  "use strict";

  /**
   * Announce a message to screen readers via polite or assertive live regions
   * and update the visible status inspector if present.
   */
  function announce(message, priority = "polite") {
    const regionId =
      priority === "assertive" ? "a11y-alert-announcer" : "a11y-live-announcer";
    const region = document.getElementById(regionId);
    if (region) {
      region.textContent = "";
      window.requestAnimationFrame(() => {
        region.textContent = message;
      });
    }

    const visibleLog = document.getElementById("a11y-last-announcement");
    if (visibleLog) {
      visibleLog.textContent = message;
    }
  }

  /**
   * Helper: check if the user is currently typing in an editable field.
   */
  function isEditableTarget(target) {
    if (!target || !(target instanceof HTMLElement)) return false;
    const tag = target.tagName;
    return (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT" ||
      target.isContentEditable
    );
  }

  /**
   * 1. WAI-ARIA Tabs Pattern (role="tablist", role="tab", role="tabpanel")
   */
  function initTabs() {
    const tablists = document.querySelectorAll('[role="tablist"]');
    tablists.forEach((tablist) => {
      const tabs = Array.from(tablist.querySelectorAll('[role="tab"]'));
      if (tabs.length === 0) return;

      function activateTab(nextTab, shouldFocus = true) {
        tabs.forEach((tab) => {
          const isSelected = tab === nextTab;
          tab.setAttribute("aria-selected", isSelected ? "true" : "false");
          tab.setAttribute("tabindex", isSelected ? "0" : "-1");
          const panelId = tab.getAttribute("aria-controls");
          if (panelId) {
            const panel = document.getElementById(panelId);
            if (panel) {
              panel.hidden = !isSelected;
            }
          }
        });

        if (shouldFocus) {
          nextTab.focus();
        }
        const label = nextTab.textContent.trim().replace(/\s+/g, " ");
        announce(`Tab selected: ${label}`);
      }

      tabs.forEach((tab, index) => {
        tab.addEventListener("click", () => activateTab(tab, false));

        tab.addEventListener("keydown", (event) => {
          let targetIndex = null;
          if (event.key === "ArrowRight" || event.key === "ArrowDown") {
            targetIndex = (index + 1) % tabs.length;
          } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
            targetIndex = (index - 1 + tabs.length) % tabs.length;
          } else if (event.key === "Home") {
            targetIndex = 0;
          } else if (event.key === "End") {
            targetIndex = tabs.length - 1;
          }

          if (targetIndex !== null) {
            event.preventDefault();
            activateTab(tabs[targetIndex], true);
          }
        });
      });
    });
  }

  /**
   * 2. WAI-ARIA Radio Group Pattern (role="radiogroup", role="radio")
   */
  function initRadioGroups() {
    const groups = document.querySelectorAll('[role="radiogroup"]');
    groups.forEach((group) => {
      const radios = Array.from(group.querySelectorAll('[role="radio"]'));
      if (radios.length === 0) return;

      function selectRadio(targetRadio, shouldFocus = true) {
        radios.forEach((radio) => {
          const isChecked = radio === targetRadio;
          radio.setAttribute("aria-checked", isChecked ? "true" : "false");
          radio.setAttribute("tabindex", isChecked ? "0" : "-1");
          const indicator = radio.querySelector(".a11y-radio-indicator");
          if (indicator) {
            indicator.textContent = isChecked ? "●" : "";
          }
        });

        if (shouldFocus) {
          targetRadio.focus();
        }

        const titleEl = targetRadio.querySelector(".a11y-radio-card__title");
        const label = titleEl
          ? titleEl.textContent.trim()
          : targetRadio.textContent.trim();
        announce(`Selected default agent: ${label}`);
      }

      radios.forEach((radio, index) => {
        radio.addEventListener("click", () => selectRadio(radio, false));

        radio.addEventListener("keydown", (event) => {
          let nextIndex = null;
          if (event.key === "ArrowRight" || event.key === "ArrowDown") {
            nextIndex = (index + 1) % radios.length;
          } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
            nextIndex = (index - 1 + radios.length) % radios.length;
          } else if (event.key === "Home") {
            nextIndex = 0;
          } else if (event.key === "End") {
            nextIndex = radios.length - 1;
          } else if (event.key === " " || event.key === "Enter") {
            event.preventDefault();
            selectRadio(radio, true);
            return;
          }

          if (nextIndex !== null) {
            event.preventDefault();
            selectRadio(radios[nextIndex], true);
          }
        });
      });
    });
  }

  /**
   * 3. Roving Tabindex for Toolbars (role="toolbar") & Navigation ([data-roving-nav])
   */
  function initRovingContainers() {
    const containers = document.querySelectorAll(
      '[role="toolbar"], [data-roving-nav]'
    );

    containers.forEach((container) => {
      const items = Array.from(
        container.querySelectorAll(
          'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])'
        )
      );
      if (items.length === 0) return;

      // Ensure first item is tabbable if roving toolbar
      if (container.getAttribute("role") === "toolbar") {
        items.forEach((item, idx) => {
          item.setAttribute("tabindex", idx === 0 ? "0" : "-1");
        });
      }

      items.forEach((item, index) => {
        item.addEventListener("keydown", (event) => {
          let nextIndex = null;
          if (event.key === "ArrowRight" || event.key === "ArrowDown") {
            nextIndex = (index + 1) % items.length;
          } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
            nextIndex = (index - 1 + items.length) % items.length;
          } else if (event.key === "Home") {
            nextIndex = 0;
          } else if (event.key === "End") {
            nextIndex = items.length - 1;
          }

          if (nextIndex !== null) {
            event.preventDefault();
            if (container.getAttribute("role") === "toolbar") {
              items.forEach((el, idx) =>
                el.setAttribute("tabindex", idx === nextIndex ? "0" : "-1")
              );
            }
            items[nextIndex].focus();
          }
        });
      });
    });
  }

  /**
   * 4. WAI-ARIA Switch (role="switch") & Toggle Buttons (aria-pressed)
   */
  function initSwitchesAndToggles() {
    const switches = document.querySelectorAll('[role="switch"]');
    switches.forEach((sw) => {
      sw.addEventListener("click", () => {
        const isChecked = sw.getAttribute("aria-checked") === "true";
        const nextState = !isChecked;
        sw.setAttribute("aria-checked", nextState ? "true" : "false");
        const labelId = sw.getAttribute("aria-labelledby");
        const labelEl = labelId ? document.getElementById(labelId) : null;
        const label = labelEl
          ? labelEl.textContent.trim()
          : sw.getAttribute("aria-label") || "Setting";
        announce(`${label}: ${nextState ? "enabled" : "disabled"}`);
      });
    });

    // Password show/hide toggle buttons
    const passwordToggles = document.querySelectorAll("[data-password-toggle]");
    passwordToggles.forEach((btn) => {
      btn.addEventListener("click", () => {
        const inputId = btn.getAttribute("aria-controls");
        const input = inputId ? document.getElementById(inputId) : null;
        if (!input) return;

        const isShown = btn.getAttribute("aria-pressed") === "true";
        const nextShown = !isShown;
        input.type = nextShown ? "text" : "password";
        btn.setAttribute("aria-pressed", nextShown ? "true" : "false");
        btn.setAttribute(
          "aria-label",
          nextShown ? "Hide password" : "Show password"
        );
        btn.textContent = nextShown ? "Hide" : "Show";
        announce(nextShown ? "Password shown as plain text" : "Password hidden");
      });
    });
  }

  /**
   * 5. Accessible Spinbutton Steppers ([data-stepper])
   */
  function initSteppers() {
    const steppers = document.querySelectorAll("[data-stepper]");
    steppers.forEach((stepper) => {
      const spinbutton = stepper.querySelector('[role="spinbutton"]');
      const decBtn = stepper.querySelector("[data-stepper-dec]");
      const incBtn = stepper.querySelector("[data-stepper-inc]");
      if (!spinbutton) return;

      const min = Number(spinbutton.getAttribute("aria-valuemin") || 1);
      const max = Number(spinbutton.getAttribute("aria-valuemax") || 10);
      const unit = spinbutton.getAttribute("data-unit") || "";

      function updateValue(nextVal) {
        const clamped = Math.max(min, Math.min(max, nextVal));
        spinbutton.setAttribute("aria-valuenow", String(clamped));
        const textVal = unit ? `${clamped} ${unit}` : String(clamped);
        spinbutton.setAttribute("aria-valuetext", textVal);
        spinbutton.textContent = String(clamped);
        const labelId = spinbutton.getAttribute("aria-labelledby");
        const labelEl = labelId ? document.getElementById(labelId) : null;
        const label = labelEl ? labelEl.textContent.trim() : "Value";
        announce(`${label}: ${textVal}`);
      }

      if (decBtn) {
        decBtn.addEventListener("click", () => {
          const current = Number(spinbutton.getAttribute("aria-valuenow") || min);
          updateValue(current - 1);
        });
      }

      if (incBtn) {
        incBtn.addEventListener("click", () => {
          const current = Number(spinbutton.getAttribute("aria-valuenow") || min);
          updateValue(current + 1);
        });
      }

      spinbutton.addEventListener("keydown", (event) => {
        const current = Number(spinbutton.getAttribute("aria-valuenow") || min);
        if (event.key === "ArrowUp") {
          event.preventDefault();
          updateValue(current + 1);
        } else if (event.key === "ArrowDown") {
          event.preventDefault();
          updateValue(current - 1);
        } else if (event.key === "Home") {
          event.preventDefault();
          updateValue(min);
        } else if (event.key === "End") {
          event.preventDefault();
          updateValue(max);
        }
      });
    });
  }

  /**
   * 6. WAI-ARIA Menu Button Pattern (aria-haspopup="menu" + role="menu")
   */
  function initMenus() {
    const triggers = document.querySelectorAll('[aria-haspopup="menu"]');
    triggers.forEach((trigger) => {
      const menuId = trigger.getAttribute("aria-controls");
      const menu = menuId ? document.getElementById(menuId) : null;
      if (!menu) return;

      const items = Array.from(menu.querySelectorAll('[role="menuitem"]'));

      function openMenu(focusIndex = 0) {
        trigger.setAttribute("aria-expanded", "true");
        menu.hidden = false;
        items.forEach((item, idx) => {
          item.setAttribute("tabindex", idx === focusIndex ? "0" : "-1");
        });
        if (items[focusIndex]) {
          items[focusIndex].focus();
        }
      }

      function closeMenu(returnFocus = true) {
        trigger.setAttribute("aria-expanded", "false");
        menu.hidden = true;
        if (returnFocus) {
          trigger.focus();
        }
      }

      trigger.addEventListener("click", () => {
        const isExpanded = trigger.getAttribute("aria-expanded") === "true";
        if (isExpanded) {
          closeMenu(true);
        } else {
          openMenu(0);
        }
      });

      trigger.addEventListener("keydown", (event) => {
        if (event.key === "ArrowDown") {
          event.preventDefault();
          openMenu(0);
        } else if (event.key === "ArrowUp") {
          event.preventDefault();
          openMenu(items.length - 1);
        } else if (event.key === "Escape") {
          closeMenu(true);
        }
      });

      items.forEach((item, index) => {
        item.addEventListener("keydown", (event) => {
          if (event.key === "ArrowDown") {
            event.preventDefault();
            const next = (index + 1) % items.length;
            items[next].focus();
          } else if (event.key === "ArrowUp") {
            event.preventDefault();
            const prev = (index - 1 + items.length) % items.length;
            items[prev].focus();
          } else if (event.key === "Home") {
            event.preventDefault();
            items[0].focus();
          } else if (event.key === "End") {
            event.preventDefault();
            items[items.length - 1].focus();
          } else if (event.key === "Escape") {
            event.preventDefault();
            closeMenu(true);
          } else if (event.key === "Tab") {
            closeMenu(false);
          }
        });

        item.addEventListener("click", () => {
          const text = item.textContent.trim().replace(/\s+/g, " ");
          closeMenu(true);
          announce(`Activated menu item: ${text}`);
        });
      });

      document.addEventListener("click", (event) => {
        if (
          !menu.hidden &&
          !menu.contains(event.target) &&
          !trigger.contains(event.target)
        ) {
          closeMenu(false);
        }
      });
    });
  }

  /**
   * 7. Accessible Modal Dialogs (<dialog> with focus trap & return focus)
   */
  let lastDialogTrigger = null;

  function openDialogById(dialogId, triggerEl = null) {
    const dialog = document.getElementById(dialogId);
    if (!dialog) return;

    lastDialogTrigger =
      triggerEl ||
      (document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null);

    if (typeof dialog.showModal === "function") {
      if (!dialog.open) {
        dialog.showModal();
      }
    } else {
      dialog.setAttribute("open", "");
    }

    const focusTarget =
      dialog.querySelector("[autofocus]") ||
      dialog.querySelector(
        'input:not([disabled]), select:not([disabled]), button:not([disabled]), [tabindex]:not([tabindex="-1"])'
      );
    if (focusTarget instanceof HTMLElement) {
      focusTarget.focus();
    }

    const titleId = dialog.getAttribute("aria-labelledby");
    const titleEl = titleId ? document.getElementById(titleId) : null;
    if (titleEl) {
      announce(`Opened dialog: ${titleEl.textContent.trim()}`);
    }
  }

  function closeDialog(dialog) {
    if (!dialog) return;
    if (typeof dialog.close === "function" && dialog.open) {
      dialog.close();
    } else {
      dialog.removeAttribute("open");
    }
    if (lastDialogTrigger && typeof lastDialogTrigger.focus === "function") {
      lastDialogTrigger.focus();
    }
    announce("Dialog closed");
  }

  function initDialogs() {
    const openBtns = document.querySelectorAll("[data-dialog-open]");
    openBtns.forEach((btn) => {
      btn.addEventListener("click", () => {
        const dialogId = btn.getAttribute("data-dialog-open");
        if (dialogId) {
          openDialogById(dialogId, btn);
        }
      });
    });

    const closeBtns = document.querySelectorAll("[data-dialog-close]");
    closeBtns.forEach((btn) => {
      btn.addEventListener("click", () => {
        const dialog = btn.closest("dialog, [role='dialog']");
        closeDialog(dialog);
      });
    });

    const dialogs = document.querySelectorAll("dialog, [role='dialog']");
    dialogs.forEach((dialog) => {
      dialog.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          closeDialog(dialog);
          return;
        }

        if (event.key === "Tab") {
          const focusables = Array.from(
            dialog.querySelectorAll(
              'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
            )
          ).filter((el) => !el.closest("[hidden]"));

          if (focusables.length === 0) return;
          const first = focusables[0];
          const last = focusables[focusables.length - 1];

          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last.focus();
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first.focus();
          }
        }
      });
    });
  }

  /**
   * 8. Sortable Accessible Data Table (th[aria-sort])
   */
  function initSortableTables() {
    const tables = document.querySelectorAll("table[data-sortable-table]");
    tables.forEach((table) => {
      const headers = Array.from(table.querySelectorAll("th[aria-sort]"));
      const tbody = table.querySelector("tbody");
      if (!tbody || headers.length === 0) return;

      headers.forEach((th, colIndex) => {
        const btn = th.querySelector("button");
        if (!btn) return;

        btn.addEventListener("click", () => {
          const currentSort = th.getAttribute("aria-sort");
          const nextSort =
            currentSort === "ascending" ? "descending" : "ascending";

          headers.forEach((otherTh) => {
            const isTarget = otherTh === th;
            otherTh.setAttribute("aria-sort", isTarget ? nextSort : "none");
            const icon = otherTh.querySelector(".a11y-sort-icon");
            if (icon) {
              icon.textContent = isTarget
                ? nextSort === "ascending"
                  ? "▲"
                  : "▼"
                : "↕";
            }
          });

          const rows = Array.from(tbody.querySelectorAll("tr"));
          rows.sort((rowA, rowB) => {
            const cellA = rowA.children[colIndex];
            const cellB = rowB.children[colIndex];
            const valA =
              (cellA && cellA.getAttribute("data-sort-value")) ||
              (cellA ? cellA.textContent.trim() : "");
            const valB =
              (cellB && cellB.getAttribute("data-sort-value")) ||
              (cellB ? cellB.textContent.trim() : "");

            const numA = Number(valA);
            const numB = Number(valB);
            const cmp =
              !Number.isNaN(numA) && !Number.isNaN(numB)
                ? numA - numB
                : valA.localeCompare(valB, undefined, { numeric: true });

            return nextSort === "ascending" ? cmp : -cmp;
          });

          rows.forEach((row) => tbody.appendChild(row));

          const colName = btn.getAttribute("data-col-name") || btn.textContent.trim();
          announce(`Sorted table by ${colName}, ${nextSort}`);
        });
      });
    });
  }

  /**
   * 9. Live Agent Log Stream Controls (role="log" aria-live="polite")
   */
  function initLiveLogControls() {
    const logContainer = document.getElementById("agent-log-output");
    if (!logContainer) return;

    let stepCounter = 5;
    const sampleMessages = [
      "Verified landmark roles (<header>, <nav>, <main>, <aside>, <footer>)... PASS",
      "Checked keyboard roving tabindex on [role='tablist'] and [role='radiogroup']... PASS",
      "Validated WCAG 2.1 AA contrast ratios and 48px touch targets... PASS",
      "Tested modal dialog focus trap and Escape restoration... PASS"
    ];

    const toggleBtn = document.querySelector("[data-log-toggle]");
    if (toggleBtn) {
      toggleBtn.addEventListener("click", () => {
        const isPaused = toggleBtn.getAttribute("aria-pressed") === "true";
        const nextPaused = !isPaused;
        toggleBtn.setAttribute("aria-pressed", nextPaused ? "true" : "false");
        toggleBtn.textContent = nextPaused ? "▶ Resume stream" : "⏸ Pause stream";
        logContainer.setAttribute("aria-live", nextPaused ? "off" : "polite");
        announce(
          nextPaused
            ? "Live agent output stream paused (aria-live set to off)"
            : "Live agent output stream resumed (aria-live set to polite)"
        );
      });
    }

    const appendBtn = document.querySelector("[data-log-append]");
    if (appendBtn) {
      appendBtn.addEventListener("click", () => {
        const msg =
          sampleMessages[(stepCounter - 5) % sampleMessages.length];
        const line = document.createElement("div");
        const time = `06:58:${String((stepCounter * 7) % 60).padStart(2, "0")}`;
        line.textContent = `[${time}] Step ${stepCounter}: ${msg}`;
        logContainer.appendChild(line);
        stepCounter += 1;
      });
    }

    const clearBtn = document.querySelector("[data-log-clear]");
    if (clearBtn) {
      clearBtn.addEventListener("click", () => {
        logContainer.innerHTML =
          "<div>[06:58:00] Log cleared by keyboard or button action. Waiting for next event…</div>";
        announce("Agent log output cleared");
      });
    }
  }

  /**
   * 10. Accessible Form Validation (aria-invalid, aria-describedby, role="alert")
   */
  function initAccessibleForms() {
    const forms = document.querySelectorAll("form[data-a11y-validate]");
    forms.forEach((form) => {
      const summary = form.querySelector(".a11y-error-summary");
      const summaryList = form.querySelector(".a11y-error-summary__list");

      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const fields = Array.from(
          form.querySelectorAll("input[required], input[aria-required='true'], select[required]")
        );
        const errors = [];

        fields.forEach((field) => {
          const errorId = field.getAttribute("data-error-id");
          const errorEl = errorId ? document.getElementById(errorId) : null;
          const labelEl = form.querySelector(`label[for="${field.id}"]`);
          const labelText = labelEl
            ? labelEl.textContent.replace("*", "").trim()
            : field.name || "Field";

          const val = field.value.trim();
          let errorMessage = "";

          if (!val) {
            errorMessage = `${labelText} is required.`;
          } else if (field.type === "email" && !val.includes("@")) {
            errorMessage = `Enter a valid work email address containing @.`;
          } else if (
            field.minLength > 0 &&
            val.length < field.minLength
          ) {
            errorMessage = `${labelText} must be at least ${field.minLength} characters.`;
          }

          if (errorMessage) {
            field.setAttribute("aria-invalid", "true");
            if (errorEl) {
              errorEl.textContent = errorMessage;
              errorEl.hidden = false;
            }
            errors.push({ id: field.id, message: errorMessage });
          } else {
            field.setAttribute("aria-invalid", "false");
            if (errorEl) {
              errorEl.hidden = true;
            }
          }
        });

        if (errors.length > 0) {
          if (summary && summaryList) {
            summaryList.innerHTML = "";
            errors.forEach((err) => {
              const li = document.createElement("li");
              const link = document.createElement("a");
              link.href = `#${err.id}`;
              link.textContent = err.message;
              link.addEventListener("click", (e) => {
                e.preventDefault();
                const target = document.getElementById(err.id);
                if (target) target.focus();
              });
              li.appendChild(link);
              summaryList.appendChild(li);
            });
            summary.hidden = false;
            summary.focus();
          }
          announce(
            `Form has ${errors.length} validation ${
              errors.length === 1 ? "error" : "errors"
            }.`,
            "assertive"
          );
        } else {
          if (summary) {
            summary.hidden = true;
          }
          const dialog = form.closest("dialog");
          if (dialog) {
            closeDialog(dialog);
          }
          const formName = form.getAttribute("aria-label") || "Form";
          announce(`${formName} submitted successfully.`);
        }
      });
    });
  }

  /**
   * 11. Global Keyboard Shortcuts (/, ?, Alt+N, Alt+1..4)
   */
  function initGlobalShortcuts() {
    document.addEventListener("keydown", (event) => {
      // Alt+N: Open New Run modal dialog
      if (event.altKey && (event.key === "n" || event.key === "N")) {
        const dialog = document.getElementById("new-run-dialog");
        if (dialog) {
          event.preventDefault();
          openDialogById("new-run-dialog");
          return;
        }
      }

      // Alt+1..4: Switch primary tabs
      if (event.altKey && ["1", "2", "3", "4"].includes(event.key)) {
        const index = Number(event.key) - 1;
        const primaryTabs = document.querySelectorAll(
          '[role="tablist"] [role="tab"]'
        );
        if (primaryTabs[index]) {
          event.preventDefault();
          primaryTabs[index].click();
          primaryTabs[index].focus();
          return;
        }
      }

      // Single-character shortcuts only when not typing in an input/textarea
      if (isEditableTarget(event.target) || event.metaKey || event.ctrlKey || event.altKey) {
        return;
      }

      if (event.key === "/") {
        const searchInput = document.getElementById("workspace-search-input");
        if (searchInput) {
          event.preventDefault();
          searchInput.focus();
          announce("Focused workspace search input");
        }
      } else if (event.key === "?") {
        const shortcutsDialog = document.getElementById("shortcuts-dialog");
        if (shortcutsDialog) {
          event.preventDefault();
          openDialogById("shortcuts-dialog");
        }
      }
    });
  }

  function initAll() {
    initTabs();
    initRadioGroups();
    initRovingContainers();
    initSwitchesAndToggles();
    initSteppers();
    initMenus();
    initDialogs();
    initSortableTables();
    initLiveLogControls();
    initAccessibleForms();
    initGlobalShortcuts();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initAll);
  } else {
    initAll();
  }
})();
