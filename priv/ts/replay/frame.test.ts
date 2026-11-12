import { afterEach, expect, test } from 'volt:test'

import { html } from '../test/hooks'

afterEach(() => {
  document.body.replaceChildren()
})

// The replay frame's container, as PhoenixReplay.Web.Live.Frame renders it,
// around a replayed page whose button opens the file picker of an upload
// input with showPicker(), as ordinary app code may.
const page = (inert: boolean): HTMLElement => {
  const container = html(`
    <div data-phx-main ${inert ? 'inert' : ''}>
      <label for="avatar">Avatar</label>
      <input id="avatar" type="file" name="avatar" data-phx-upload-ref="phx-1" />
      <button id="pick" type="button" style="width: 120px; height: 40px">Pick</button>
      <div id="drop" phx-drop-target="phx-1" style="width: 120px; height: 40px">Drop</div>
    </div>
  `)
  const input = container.querySelector('#avatar') as HTMLInputElement
  container.querySelector('#pick')?.addEventListener('click', () => input.showPicker())
  document.body.append(container)
  return container
}

const focusable = (element: HTMLElement): boolean => {
  element.focus()
  return document.activeElement === element
}

// What the pointer, a click or a dropped file, lands on at the element's centre.
const hit = (element: HTMLElement): Element | null => {
  const { left, top, width, height } = element.getBoundingClientRect()
  return document.elementFromPoint(left + width / 2, top + height / 2)
}

const control = (container: HTMLElement, selector: string): HTMLElement =>
  container.querySelector(selector) as HTMLElement

test('keeps the replayed page out of reach of the keyboard and the pointer, showPicker buttons and drop targets included', () => {
  const container = page(true)

  for (const selector of ['#avatar', '#pick', '#drop', 'label']) {
    const element = control(container, selector)
    // Neither Tab nor focus() reaches it, so no Space or Enter presses it.
    expect(focusable(element)).toBe(false)
    expect(container.contains(hit(element))).toBe(false)
  }
})

test('without inert, the same page is in reach', () => {
  const container = page(false)
  const pick = control(container, '#pick')
  const drop = control(container, '#drop')

  expect(focusable(control(container, '#avatar'))).toBe(true)
  expect(focusable(pick)).toBe(true)
  expect(hit(pick)).toBe(pick)
  expect(hit(drop)).toBe(drop)
})
