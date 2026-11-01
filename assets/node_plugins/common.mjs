// QQ official groups cannot receive OneBot merged-forward messages. The
// adapter renders long mixed forwards as an image, preserving their order.
export default {
  async makeForwardMsg(e, messages) {
    return { type: 'forward', messages };
  },
  sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
};
