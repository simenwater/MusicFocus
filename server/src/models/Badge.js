const mongoose = require('mongoose');

const badgeSchema = new mongoose.Schema({
  userId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true
  },
  date: {
    type: Date,
    required: true
  },
  type: {
    type: String,
    required: true,
    enum: ['daily', 'weekly', 'monthly']
  },
  level: {
    type: String,
    required: true,
    enum: ['bronze', 'silver', 'gold', 'platinum']
  },
  focusTime: {
    type: Number,
    required: true
  },
  createdAt: {
    type: Date,
    default: Date.now
  }
});

// 复合索引确保每个用户每天每种类型的勋章只有一个
badgeSchema.index({ userId: 1, date: 1, type: 1 }, { unique: true });

module.exports = mongoose.model('Badge', badgeSchema); 